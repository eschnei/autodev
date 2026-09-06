// autoDev — the Control API (Marj PRD §10; M-MARJ-0).
//
// The ONE constrained surface through which a controller (Marj), the CLI's
// deterministic commands, and the MCP adapter act on autoDev. Model-neutral:
// every operation is a plain function {op, params} → {ok, result | error}.
// The Control API is the enforcement boundary: it consults core state, the
// gates, and policy; a controller can only ASK. Every call is recorded as an
// event with controller attribution (PRD §20).
//
// Nothing here talks to a model. Executor jobs it starts go through the same
// executor seam as the CLI; Brain through the same client; gates through
// src/core/workflow/gates.mjs.

import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolveProject, saveProject, loadRegistry, loadProject } from '../core/project.mjs';
import { Tracker } from '../core/tracker.mjs';
import { readWorkflowState, nextAction, describeState } from '../core/workflow/state.mjs';
import { approve as gateApprove, reject as gateReject, jobFor, GateError } from '../core/workflow/gates.mjs';
import { headlessAllowlist, assertAllowlistInvariants } from '../core/permissions.mjs';
import { makeJob, getExecutor, listExecutors, hasExecutor } from '../executors/executor.mjs';
import { appendEvent, readEvents } from '../core/events.mjs';
import { StateRepo, StateError } from '../core/state.mjs';
import { brainStatus, ensureBrainProject, contextForJob, recordHandoff, recordGateDecision, describeBrain } from '../brain/index.mjs';
import { git, currentBranch, commitsAhead } from '../core/git.mjs';
import { scanContamination, contaminationDelta, describeContamination, isSidecarProject } from '../core/contamination.mjs';
import { wantsLane, ensureLane, listLanes, removeLane } from '../core/workspace.mjs';
import { isFeature } from '../core/workflow/state.mjs';
import '../executors/claude/index.mjs';
import '../executors/codex/index.mjs';

export class ControlError extends Error { constructor(m, code = 'invalid') { super(m); this.code = code; } }

// The catalog is the contract a controller sees. Descriptions are written for a
// model: what the op does, what it needs, what it will never do.
export const OPERATIONS = Object.freeze({
  get_status:           { params: {}, reads: true, description: 'Current project status: identity, branch, executor, Brain, board counts, what awaits a human, the next deterministic action.' },
  list_projects:        { params: {}, reads: true, description: 'Every project registered on this machine with its last-known clone path.' },
  get_project:          { params: { project: 'id | key | name (optional; default: current)' }, reads: true, description: 'Project metadata (executor, tracker mode, Brain link, migration, pause).' },
  list_requirements:    { params: { stage: 'optional stage key filter' }, reads: true, description: 'Board issues in this instance\'s lane: id, uid, title, stage, labels. Features are requirements; other issues are stories/tasks.' },
  get_requirement:      { params: { id: 'AD-n | uid | title fragment' }, reads: true, description: 'One board issue in full: description, history, comments, relations, attachments.' },
  get_task:             { params: { id: 'AD-n | uid' }, reads: true, description: 'Alias of get_requirement for stories/tasks.' },
  get_blockers:         { params: {}, reads: true, description: 'Issues waiting on a human: Gate 1, Gate 2, Blocked (H), Clarifying (H) — with the question or the review artifact when known.' },
  get_next:             { params: {}, reads: true, description: 'What autoDev would do next and why (deterministic; no model).' },
  get_diff_summary:     { params: { branch: 'optional; default: current branch', base: 'optional; default: the default branch' }, reads: true, description: 'git diff --stat and commits ahead for a branch vs its base. Read-only.' },
  get_verification:     { params: { id: 'optional issue id' }, reads: true, description: 'The most recent verification evidence recorded (tests/lint/build results, contamination check) for the project or an issue.' },
  run_verification:     { params: { id: 'optional issue id to attach the evidence to' }, reads: false, description: 'Run the deployment\'s configured test, lint, and build commands in the repository and record the evidence. Never a model claim: real exit codes.' },
  continue_requirement: { params: { id: 'issue id (optional; default: the next eligible story)', executor: 'optional executor id', role: 'optional role', instructions: 'optional extra instructions' }, reads: false, description: 'Do one bounded unit of work on an issue through the selected executor, with Brain context in front and a handoff after. Never crosses a human gate.' },
  start_requirement:    { params: { title: 'required', description: 'optional spec/brief', bug: 'optional boolean' }, reads: false, description: 'Capture new work as a feature (or bug) issue at New Request. Nothing is built until Gate 1.' },
  pause_requirement:    { params: { id: 'optional issue id; without it the whole project pauses', reason: 'optional' }, reads: false, description: 'Pause: the heartbeat skips the project (or the issue is moved to Blocked (H) with the reason). Reversible.' },
  resume_requirement:   { params: { id: 'optional issue id' }, reads: false, description: 'Undo pause.' },
  select_executor:      { params: { executor: 'claude | codex' }, reads: false, description: 'Set the project\'s default executor. Refuses unregistered executors.' },
  request_review:       { params: { id: 'issue id', executor: 'optional executor id' }, reads: false, description: 'Run an independent review job (review role, fresh context) on an issue\'s diff; records the verdict as a comment + handoff. Does not move the card.' },
  approve_gate:         { params: { id: 'issue id', note: 'optional' }, reads: false, description: 'Record the HUMAN\'s approval at Gate 1 or Gate 2 (only when the user explicitly approved). Gate 1 → breakdown job; Gate 2 → merge job + verification. Refused when the issue is not at a gate.' },
  reject_gate:          { params: { id: 'issue id', reason: 'required' }, reads: false, description: 'Record the HUMAN\'s rejection at a gate with the reason; Gate 2 → back to AI Development.' },
  cancel_job:           { params: { job_id: 'job id' }, reads: false, description: 'Cancel a running executor job (best effort).' },
  list_lanes:           { params: {}, reads: true, description: 'Isolated story worktrees (lanes) this project has: issue, branch, path. Read-only.' },
  release_lane:         { params: { id: 'issue id', force: 'optional boolean: discard uncommitted work in the lane' }, reads: false, description: 'Remove a story\'s isolated worktree (after merge, or to reset it). Refuses a dirty lane unless force.' },
});

const running = new Map(); // job_id → { executor, job }

// A ControlSession binds the API to one repo (cwd) and one caller identity.
export class ControlSession {
  #cwd; #ctx = null; #actor;
  constructor({ cwd = process.cwd(), actor = { kind: 'cli', name: 'autodev' } } = {}) { this.#cwd = cwd; this.#actor = actor; }
  get actor() { return this.#actor; }
  async context() {
    if (this.#ctx) return this.#ctx;
    const ctx = await resolveProject(this.#cwd);
    if (ctx.legacy) {
      ctx.executorId = ctx.project?.executor?.default || ctx.legacy.executor?.default || 'claude';
      ctx.brain = await brainStatus(ctx.legacy, ctx.project);
      if (ctx.brain.state === 'connected') { try { await ensureBrainProject(ctx.brain, ctx); } catch (e) { ctx.brain = { state: 'degraded', url: ctx.brain.url, reason: `registration failed: ${e.message}` }; } }
    } else ctx.brain = { state: 'off' };
    this.#ctx = ctx;
    return ctx;
  }
  capabilities() { return Object.keys(OPERATIONS); }

  // The single entry point. Validates op + params, executes, records.
  async call(op, params = {}) {
    if (!OPERATIONS[op]) return { ok: false, error: { code: 'unknown_op', message: `unknown operation "${op}" (see capabilities)` } };
    const ctx = await this.context();
    const started = new Date().toISOString();
    let out;
    try {
      const fn = this[`op_${op}`];
      if (!fn) throw new ControlError(`operation "${op}" is not implemented`, 'unimplemented');
      out = { ok: true, result: await fn.call(this, ctx, params || {}) };
    } catch (e) {
      const code = e instanceof ControlError ? e.code : e instanceof GateError ? 'gate' : e instanceof StateError ? 'state' : 'error';
      out = { ok: false, error: { code, message: e.message } };
    }
    if (ctx.project && !OPERATIONS[op].reads) {
      try { appendEvent(ctx.project.id, { type: 'control.call', op, params: redact(params), ok: out.ok, error: out.error?.message || null, actor: this.#actor, started, ended: new Date().toISOString() }); } catch {}
    }
    return out;
  }

  // ---- helpers ------------------------------------------------------------------------
  #tracker(ctx) {
    if (!ctx.legacy) throw new ControlError('this repository has no autoDev deployment — run `autodev init` (nothing is written into the repo)', 'not_configured');
    if ((ctx.legacy.tracker?.kind || 'local') !== 'local') throw new ControlError(`tracker.kind=${ctx.legacy.tracker.kind}: the Control API works on the local board (API trackers via the plugin path for now)`, 'unsupported');
    return Tracker.for(ctx);
  }
  #issue(tracker, id) {
    if (!id) throw new ControlError('id is required', 'invalid');
    const all = tracker.readIssues();
    const s = String(id).toLowerCase();
    const hit = all.find((i) => i.id.toLowerCase() === s || (i.uid || '').toLowerCase() === s) || (() => { const h = all.filter((i) => i.title.toLowerCase().includes(s)); return h.length === 1 ? h[0] : null; })();
    if (!hit) throw new ControlError(`no issue matches "${id}"`, 'not_found');
    return hit;
  }
  #paused(ctx) { return ctx.project?.paused || null; }
  async #runJob(ctx, { task, role, executorId, issue, extraContext = {}, isolate = true }) {
    const exec = executorId || ctx.executorId;
    if (!hasExecutor(exec)) throw new ControlError(`no executor "${exec}" registered (available: ${listExecutors().join(', ')})`, 'invalid');
    const executor = getExecutor(exec);
    const allow = assertAllowlistInvariants(headlessAllowlist(ctx.legacy), ctx.legacy);
    // M8A: a story job gets its own worktree on its story branch; everything else runs on the main checkout
    let lane = null;
    if (isolate && issue && wantsLane(issue, ctx.legacy, { isFeature: isFeature(issue, ctx.legacy) })) {
      try { lane = ensureLane({ root: ctx.identity.root, projectId: ctx.project.id, cfg: ctx.legacy, issue, all: this.#tracker(ctx).readIssues() }); }
      catch (e) { throw new ControlError(`could not prepare an isolated lane for ${issue.id}: ${e.message}`, 'workspace'); }
    }
    const cwd = lane ? lane.cwd : ctx.identity.root;
    const sidecar = isSidecarProject(ctx);
    const before = scanContamination(cwd, { sidecar });
    const job = makeJob({ role, task: lane ? `${task}\n\nWorkspace: you are in an isolated worktree on branch ${lane.branch} (${cwd}). Commit here; never switch branches or touch the main checkout.` : task, cwd, project_id: ctx.project.id, requirement_id: issue?.uid || null, permissions: { allowed_tools: allow }, context: { branch: lane ? lane.branch : ctx.identity.branch, issue: issue?.id || null, actor: this.#actor, lane: lane ? { path: lane.cwd, branch: lane.branch, created: lane.created } : null, ...extraContext } });
    const bc = await contextForJob(ctx.brain, ctx, { role, executor: exec, branch: ctx.identity.branch, requirement_key: issue?.id });
    if (bc) { job.context.brain = { bundle_id: bc.bundle.id, memories: bc.bundle.memories.map((m) => ({ id: m.id, revision: m.revision })) }; job.task = `${bc.text}\n\n---\n\n${job.task}`; }
    running.set(job.job_id, { executor, job });
    appendEvent(ctx.project.id, { type: 'job.started', job_id: job.job_id, role, executor: exec, issue: issue?.id || null, actor: this.#actor, context_bundle_id: bc?.bundle.id || null, lane: job.context.lane });
    const result = await executor.execute(job);
    running.delete(job.job_id);
    // M12A: a job that leaves sidecar-owned artifacts in the repo is recorded as contaminated
    const contamination = contaminationDelta(cwd, before, { sidecar });
    result.contamination = contamination;
    await recordHandoff(ctx.brain, ctx, job, result, { requirement_key: issue?.id });
    appendEvent(ctx.project.id, { type: 'job.finished', job_id: job.job_id, status: result.status, executor: exec, issue: issue?.id || null, summary: (result.summary || '').slice(0, 500), files_changed: result.files_changed, commits: result.commits || [], contamination, lane: job.context.lane });
    if (contamination.length) appendEvent(ctx.project.id, { type: 'contamination.detected', job_id: job.job_id, issue: issue?.id || null, paths: contamination, cwd });
    return { job_id: job.job_id, executor: exec, role, status: result.status, summary: result.summary, files_changed: result.files_changed, commits: result.commits || [], tests_failed: result.tests_failed, reset_at: result.reset_at, brain_context: bc?.bundle.id || null, lane: job.context.lane, contamination };
  }

  // ---- reads ------------------------------------------------------------------------------
  async op_get_status(ctx) {
    if (!ctx.identity) return { configured: false, message: 'not a git repository' };
    const base = { configured: !!ctx.legacy, project: ctx.project ? { id: ctx.project.id, name: ctx.project.name, key: ctx.project.key } : null, branch: ctx.identity.branch, executor: ctx.executorId || null, executors: listExecutors(), brain: describeBrain(ctx.brain || { state: 'off' }), paused: this.#paused(ctx), state: new StateRepo().status() };
    if (!ctx.legacy) return { ...base, message: 'registered but not configured — autodev init' };
    let board = null;
    if ((ctx.legacy.tracker?.kind || 'local') === 'local') { const tr = Tracker.for(ctx); const st = readWorkflowState(tr, ctx.legacy); board = { counts: st.counts, awaiting_human: st.awaiting_human.map(brief), in_flight: st.in_flight.map(brief), eligible: st.eligible.map(brief), blocked: st.blocked.map(brief), next: nextAction(st, ctx.legacy), summary: describeState(st, ctx.legacy) }; }
    const contamination = scanContamination(ctx.identity.root, { sidecar: isSidecarProject(ctx) });
    let lanes = []; try { lanes = listLanes({ root: ctx.identity.root, projectId: ctx.project.id }); } catch {}
    return { ...base, deployment: { name: ctx.legacy.client_name, tracker: ctx.legacy.tracker?.kind || 'local', planning: ctx.legacy.planning?.engine, sidecar: !!ctx.legacy.sidecar, config_errors: ctx.legacy.validation?.errors || [] }, board, contamination, lanes };
  }
  async op_list_projects() {
    const reg = loadRegistry();
    return reg.projects.map((p) => { const pj = loadProject(p.id) || {}; return { id: p.id, name: p.name, key: pj.key || null, remote: p.remote, clones: (p.clones || []).map((c) => c.path), local_clone: (p.clones || []).map((c) => c.path).find((x) => existsSync(x)) || null, executor: pj.executor?.default || null, paused: pj.paused || null, migrated: !!pj.migrated, brain: pj.brain?.project_id || null }; });
  }
  async op_get_project(ctx, { project }) {
    if (!project) return ctx.project;
    const reg = loadRegistry();
    const s = String(project).toLowerCase();
    const hit = reg.projects.find((p) => p.id === project) || reg.projects.find((p) => (p.name || '').toLowerCase() === s) || reg.projects.find((p) => (loadProject(p.id)?.key || '').toLowerCase() === s);
    if (!hit) throw new ControlError(`no project "${project}" (list_projects)`, 'not_found');
    return loadProject(hit.id);
  }
  async op_list_requirements(ctx, { stage }) {
    const tr = this.#tracker(ctx);
    return tr.ownIssues().filter((i) => !stage || i.stage === stage).map(brief);
  }
  async op_get_requirement(ctx, { id }) { const tr = this.#tracker(ctx); return this.#issue(tr, id); }
  async op_get_task(ctx, p) { return this.op_get_requirement(ctx, p); }
  async op_get_blockers(ctx) {
    const tr = this.#tracker(ctx); const st = readWorkflowState(tr, ctx.legacy);
    const why = (i) => { const c = [...(i.comments || [])].reverse().find((x) => /🛑|blocked|question|Gate|🚦|review/i.test(x.body)); return c ? c.body.slice(0, 300) : null; };
    return { gate1: st.gates.gate1.map((i) => ({ ...brief(i), why: why(i) })), gate2: st.gates.gate2.map((i) => ({ ...brief(i), why: why(i) })), blocked: st.blocked.map((i) => ({ ...brief(i), why: why(i) })), clarifying: st.clarifying.map((i) => ({ ...brief(i), why: why(i) })), paused: this.#paused(ctx) };
  }
  async op_get_next(ctx) { const tr = this.#tracker(ctx); const st = readWorkflowState(tr, ctx.legacy); return { ...nextAction(st, ctx.legacy), paused: this.#paused(ctx) }; }
  async op_get_diff_summary(ctx, { branch, base }) {
    const root = ctx.identity.root; const b = branch || currentBranch(root); const d = base || ctx.legacy?.repo?.default_branch || 'main';
    if (!b) throw new ControlError('detached HEAD and no branch given', 'invalid');
    for (const [k, v] of [['branch', b], ['base', d]]) if (!/^[A-Za-z0-9][A-Za-z0-9._\/-]*$/.test(v) || v.includes('..')) throw new ControlError(`${k} "${v}" is not a plain ref name`, 'invalid');   // controller-supplied: never an option or a range
    const stat = git(root, ['diff', '--stat', `${d}...${b}`]) ?? git(root, ['diff', '--stat', d, b]);
    return { branch: b, base: d, stat: stat || '(no differences or base unknown)', commits_ahead: commitsAhead(root, b, d) };
  }
  async op_get_verification(ctx, { id }) {
    const ev = readEvents(ctx.project.id, { type: 'verification.recorded' }).filter((e) => !id || e.issue === id);
    return ev.at(-1) || null;
  }

  // ---- actions --------------------------------------------------------------------------------
  async op_run_verification(ctx, { id }) {
    if (!ctx.legacy) throw new ControlError('not configured', 'not_configured');
    const cmds = ctx.legacy.commands || {}; const root = ctx.identity.root; const results = {};
    for (const k of ['test', 'lint', 'build']) {
      if (!cmds[k]) { results[k] = { skipped: true }; continue; }
      const r = spawnSync('/bin/sh', ['-c', cmds[k]], { cwd: root, encoding: 'utf8', env: { ...process.env, ...(ctx.legacy.qa?.hermetic?.enabled ? ctx.legacy.qa.hermetic.env : {}) }, timeout: 15 * 60 * 1000 });
      results[k] = { command: cmds[k], exit_code: r.status, ok: r.status === 0, tail: (r.stdout + r.stderr).trim().split('\n').slice(-15).join('\n') };
    }
    const contamination = scanContamination(root, { sidecar: isSidecarProject(ctx) });
    const ok = Object.values(results).every((r) => r.skipped || r.ok) && !contamination.length;
    const evidence = { ok, results, contamination, branch: ctx.identity.branch, head: git(root, ['rev-parse', '--short', 'HEAD']) };
    appendEvent(ctx.project.id, { type: 'verification.recorded', issue: id || null, ...evidence, actor: this.#actor });
    if (id) { try { this.#tracker(ctx).comment(id, `🧪 verification (${ok ? 'PASS' : 'FAIL'}) — ${Object.entries(results).map(([k, r]) => `${k}: ${r.skipped ? 'skipped' : r.ok ? '✓' : `✗ exit ${r.exit_code}`}`).join(' · ')}`); } catch {} }
    return evidence;
  }
  async op_continue_requirement(ctx, { id, executor, role, instructions }) {
    if (this.#paused(ctx) && !id) throw new ControlError(`project is paused (${this.#paused(ctx).reason || 'no reason given'}) — resume first`, 'paused');
    const tr = this.#tracker(ctx);
    let issue = id ? this.#issue(tr, id) : null;
    if (!issue) { const st = readWorkflowState(tr, ctx.legacy); const nx = nextAction(st, ctx.legacy); if (nx.action !== 'develop' && nx.action !== 'breakdown') throw new ControlError(`nothing to continue: next is "${nx.action}" — ${nx.reason}`, 'nothing_to_do'); issue = this.#issue(tr, nx.issues[0]); }
    if (['prd_review', 'ready_for_human_review', 'ready_for_human_acceptance'].includes(issue.stage)) throw new ControlError(`${issue.id} is at a human gate (${issue.stage}); continuing would cross it — use approve_gate / reject_gate after the human decides`, 'gate');
    if (issue.stage === 'done') throw new ControlError(`${issue.id} is done`, 'invalid');
    const r = role || (issue.stage === 'breakdown' ? 'project_manager' : issue.stage === 'ai_qa' ? 'test' : 'implementation');
    const task = issue.stage === 'breakdown' ? jobFor('breakdown', issue.id, ctx.legacy).task
      : `Continue ${issue.id} (${issue.title}) at stage "${issue.stage}" per reference/devloop.md — one bounded unit of work for the ${r} role, then stop. Log every action on the board via tracker.mjs with a --note. Never move the card across a human gate.${instructions ? `\n\nAdditional operator instructions: ${instructions}` : ''}`;
    return this.#runJob(ctx, { task, role: r, executorId: executor, issue });
  }
  async op_start_requirement(ctx, { title, description, bug }) {
    if (!title) throw new ControlError('title is required', 'invalid');
    const tr = this.#tracker(ctx);
    const label = ctx.legacy.tracker?.instance_label;
    const labels = [bug ? (ctx.legacy.tracker?.labels?.route_bug || 'route:bug') : (ctx.legacy.tracker?.labels?.route_feature || 'route:feature'), ...(label ? [label] : [])];
    const id = tr.createIssue({ title, desc: description || '', stage: 'new_request', labels });
    return { id, stage: 'new_request', labels, next: bug ? 'triage (intake.bugs)' : 'intake → PRD → Gate 1' };
  }
  async op_pause_requirement(ctx, { id, reason }) {
    if (id) { const tr = this.#tracker(ctx); const i = this.#issue(tr, id); if (i.stage === 'blocked') return { id: i.id, already: true }; tr.move(i.id, 'blocked', `⏸ paused by ${this.#actor.name}${reason ? ` — ${reason}` : ''}`); return { id: i.id, stage: 'blocked', resume_to: i.stage }; }
    ctx.project.paused = { at: new Date().toISOString(), by: this.#actor.name, reason: reason || null }; saveProject(ctx.project);
    return { project: ctx.project.id, paused: ctx.project.paused };
  }
  async op_resume_requirement(ctx, { id }) {
    if (id) { const tr = this.#tracker(ctx); const i = this.#issue(tr, id); if (i.stage !== 'blocked') return { id: i.id, already: true }; const prev = [...(i.history || [])].reverse().find((h) => h.to === 'blocked')?.from || 'ready_for_ai_dev'; tr.move(i.id, prev, `▶️ resumed by ${this.#actor.name}`); return { id: i.id, stage: prev }; }
    if (!ctx.project.paused) return { project: ctx.project.id, already: true };
    delete ctx.project.paused; saveProject(ctx.project);
    return { project: ctx.project.id, paused: null };
  }
  async op_select_executor(ctx, { executor }) {
    if (!hasExecutor(executor)) throw new ControlError(`no executor "${executor}" registered (available: ${listExecutors().join(', ')})`, 'invalid');
    ctx.project.executor = { ...(ctx.project.executor || {}), default: executor }; saveProject(ctx.project); ctx.executorId = executor;
    const avail = await getExecutor(executor).available();
    return { executor, available: avail, warning: avail ? null : `${executor} CLI not found on PATH` };
  }
  async op_request_review(ctx, { id, executor }) {
    const tr = this.#tracker(ctx); const issue = this.#issue(tr, id);
    const task = `Independent review of ${issue.id} (${issue.title}) — you did NOT build this. Re-derive the verdict from the diff and the acceptance criteria per reference/devloop.md §6 (conformance · adversarial · regression; live checks advisory). Post the verdict as a comment on ${issue.id} via tracker.mjs (\`comment ${issue.id} "…"\`) naming each defect precisely. Do NOT move the card and do NOT fix anything.`;
    return this.#runJob(ctx, { task, role: 'review', executorId: executor, issue });
  }
  async op_approve_gate(ctx, { id, note }) {
    const tr = this.#tracker(ctx);
    try { new StateRepo().claim(ctx.project.id); } catch (e) { throw new ControlError(e.message, 'state'); }
    const d = gateApprove({ tracker: tr, projectId: ctx.project.id, issueId: id, by: this.#actor.name, note });
    await recordGateDecision(ctx.brain, ctx, d);
    const job = jobFor(d.next, d.issue, ctx.legacy);
    const r = await this.#runJob(ctx, { task: job.task, role: job.role, issue: this.#issue(tr, d.issue), extraContext: { gate: d.gate } });
    const after = this.#issue(tr, d.issue);
    const verified = d.next === 'breakdown' ? { stories_ready: readWorkflowState(tr, ctx.legacy).eligible.length } : { done: after.stage === 'done', stage: after.stage };
    return { gate: d.gate, issue: d.issue, moved: d.moved, next: d.next, event: d.event.id, job: r, verified };
  }
  async op_reject_gate(ctx, { id, reason }) {
    const tr = this.#tracker(ctx);
    const d = gateReject({ tracker: tr, projectId: ctx.project.id, issueId: id, by: this.#actor.name, reason });
    await recordGateDecision(ctx.brain, ctx, d);
    return { gate: d.gate, issue: d.issue, moved: d.moved, event: d.event.id };
  }
  async op_list_lanes(ctx) { return listLanes({ root: ctx.identity.root, projectId: ctx.project.id }); }
  async op_release_lane(ctx, { id, force }) {
    const tr = this.#tracker(ctx); const issue = this.#issue(tr, id);
    const lanes = listLanes({ root: ctx.identity.root, projectId: ctx.project.id }); const lane = lanes.find((l) => l.issue === issue.id);
    if (!lane) throw new ControlError(`${issue.id} has no lane`, 'not_found');
    const dirty = git(lane.path, ['status', '--porcelain']);
    if (dirty && !(force === true || force === 'true')) throw new ControlError(`lane for ${issue.id} has uncommitted work (${dirty.split('\n').length} path(s)) — commit it or pass force`, 'dirty');
    return { issue: issue.id, ...removeLane({ root: ctx.identity.root, projectId: ctx.project.id, issue, force: true }), branch_kept: lane.branch };
  }
  async op_cancel_job(ctx, { job_id }) {
    const r = running.get(job_id);
    if (!r) throw new ControlError(`no running job "${job_id}"`, 'not_found');
    await r.executor.cancel(job_id);
    return { job_id, cancelled: true };
  }
}

function brief(i) { return { id: i.id, uid: i.uid || null, title: i.title, stage: i.stage, labels: i.labels || [], updated_at: i.updated_at }; }
function redact(p) { const o = { ...p }; for (const k of Object.keys(o)) if (/token|secret|password|key$/i.test(k)) o[k] = '[redacted]'; return o; }

// Cross-project attention (M-MARJ-6): every registered project with a local
// clone, summarized read-only. Never mutates.
export async function attentionAcrossProjects({ env } = {}) {
  const reg = loadRegistry(env); const out = [];
  for (const p of reg.projects) {
    const clone = (p.clones || []).map((c) => c.path).find((x) => existsSync(x));
    if (!clone) { out.push({ id: p.id, name: p.name, available: false, reason: 'no clone on this machine' }); continue; }
    try {
      const s = new ControlSession({ cwd: clone, actor: { kind: 'system', name: 'attention' } });
      const r = await s.call('get_status');
      if (!r.ok) { out.push({ id: p.id, name: p.name, available: false, reason: r.error.message }); continue; }
      const b = r.result.board;
      out.push({ id: p.id, name: p.name, available: true, clone, configured: r.result.configured, paused: r.result.paused, awaiting_human: b?.awaiting_human || [], in_flight: b?.in_flight || [], next: b?.next || null, brain: r.result.brain });
    } catch (e) { out.push({ id: p.id, name: p.name, available: false, reason: e.message }); }
  }
  return out;
}
