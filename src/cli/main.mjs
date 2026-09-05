// autoDev — the developer-facing CLI (PRD §5; Milestone 2).
//
//   autodev                      interactive shell
//   autodev status               project + board snapshot, non-interactive
//   autodev tick <repo>          one headless heartbeat (what the launchd timer calls)
//   autodev executor [name]      show / set the default executor for this project
//   autodev doctor               the v2 preflight (scripts/doctor.sh)
//   autodev version | help
//   autodev <anything else…>     natural language, one shot, through the executor
//
// Milestone 2 contract: the CLI is the entry point; natural language and
// `continue` proxy to the existing Claude-driven autoDev behavior THROUGH the
// executor seam (no vendor CLI is invoked here). Registering a repo writes only
// under the sidecar data root — `git status` stays clean (decision D2 / G9).

import { createInterface } from 'node:readline';

import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { resolveProject, saveProject } from '../core/project.mjs';
import { Tracker } from '../core/tracker.mjs';
import { loadRoles } from '../agency/roles.mjs';
import { PersonaStore, ensurePersonas } from '../agency/personas.mjs';
import { ensureAgentsDirs } from '../core/paths.mjs';
import { projectPersonas, claudeAgentsDir } from '../executors/claude/agents.mjs';
import { readWorkflowState, nextAction, describeState } from '../core/workflow/state.mjs';
import { approve as gateApprove, reject as gateReject, jobFor, GateError } from '../core/workflow/gates.mjs';
import { brainStatus, describeBrain, ensureBrainProject, contextForJob, recordHandoff, recordGateDecision } from '../brain/index.mjs';
import { StateRepo, StateError } from '../core/state.mjs';
import { appendEvent } from '../core/events.mjs';
import { plan as migratePlan, apply as migrateApply, renderReport } from '../migrate/index.mjs';
import { defaults as schemaDefaults, validate as validateConfig } from '../core/config/schema.mjs';
import { projectDeploymentFile, projectBoardDir, ensureProjectDirs } from '../core/paths.mjs';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { headlessAllowlist, assertAllowlistInvariants } from '../core/permissions.mjs';
import { tick } from '../core/tick.mjs';
import { makeJob, getExecutor, listExecutors, hasExecutor } from '../executors/executor.mjs';
import '../executors/claude/index.mjs';
import '../executors/codex/index.mjs';
import { ControlSession, OPERATIONS, attentionAcrossProjects } from '../control/api.mjs';
import { serveStdio as serveMcp } from '../control/mcp.mjs';
import { getController, hasController, listControllers, controllerContract, executeIntent, renderAudit, IntentError } from '../controller/controller.mjs';
import { ClaudeCodeController } from '../controller/claude/index.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const VERSION = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8')).version;

const HELP = `autoDev v${VERSION}

usage: autodev [command] [args]      (no command = interactive shell)

  status                 project identity, branch, executor, board snapshot
  continue | loop        one bounded unit of work (a heartbeat) through the executor
  tick <repo>            headless heartbeat for the timer (lock, pause/probe, digest)
  executor [name]        show or set this project's default executor
  approve <id> [note]    record a human gate decision (Gate 1 → breakdown, Gate 2 → merge);
                         autoDev records it, then hands the model one bounded job
  reject <id> <reason>   record a Gate 2 rejection → back to AI Development with the reason
  next                   what the engine would do next, decided without a model
  init [--name N] [--test cmd] [--brain-url U]   v3 setup: deployment + board in the sidecar; the repo stays untouched
  migrate [--from claude] [--dry-run] [--import-user]   translate an existing Claude/autoDev project into the sidecar + Brain (non-destructive)
  state [status|remote <url>|sync|takeover|release]   the sidecar state repo (workflow reality) + its private remote
  brain [status|context [REQ]|search <q>|remember <text>]   the Brain connection (optional; degraded mode when unreachable)
  agents [sync|install]  Agency roles + persona resolution; sync = adopt existing
                         ~/.claude/agents personas into the store and project the
                         store back out; install = fetch missing (consent-gated)
  doctor                 preflight the deployment (scripts/doctor.sh)
  version | help
  <anything else>        natural language → Marj (the controller) → structured autoDev actions

Marj — the conversational controller (never the executor; autoDev decides):
  marj [status|contract|setup]   controller status · the controller contract · how to make a Claude Code session Marj
  mcp                    serve the Control API over MCP on stdio (a Claude Code session with it registered IS Marj)
  control <op> [json]    call one Control API operation deterministically (autodev control get_blockers)
  projects | attention   every registered project: what awaits you, what is in flight (cross-project)
  blockers               what is waiting on a human here, with the why
  new <title>            capture a request at New Request (nothing is built before Gate 1)
  continue <id>          one bounded unit of work on an issue (never crosses a gate)
  review <id>            an independent review job (fresh context) on an issue
  verify [id]            run the configured test/lint/build and record the evidence
  diff [branch] [base]   diff summary vs the base branch
  pause [id] [reason] | resume [id]   pause the project (heartbeat skips it) or one issue

in the shell: the same commands, plus  exit`;

// ---- context ----------------------------------------------------------------------
async function context(cwd) {
  const ctx = await resolveProject(cwd);
  ctx.executorId = ctx.project?.executor?.default || 'claude';
  ctx.executor = hasExecutor(ctx.executorId) ? getExecutor(ctx.executorId) : null;
  ctx.executorAvailable = ctx.executor ? await ctx.executor.available() : false;
  ctx.brain = ctx.legacy ? await brainStatus(ctx.legacy, ctx.project) : { state: 'off', reason: 'no deployment' };
  if (ctx.brain.state === 'connected') { try { await ensureBrainProject(ctx.brain, ctx, { log: (m) => console.error(m) }); } catch (e) { ctx.brain = { state: 'degraded', url: ctx.brain.url, reason: `registration failed: ${e.message}` }; } }
  return ctx;
}

function boardSnapshot(ctx) {
  if (!ctx.legacy || (ctx.legacy.tracker?.kind || 'local') !== 'local') return null;
  const tracker = Tracker.for(ctx);
  const counts = {};
  for (const i of tracker.readIssues()) counts[i.stage] = (counts[i.stage] || 0) + 1;
  const names = ctx.legacy.tracker?.statuses || {};
  return Object.entries(counts).map(([k, n]) => `${names[k]?.name || k}: ${n}`).join(' · ') || 'empty';
}

function banner(ctx) {
  const lines = [`autoDev v${VERSION}`, ''];
  if (!ctx.identity) { lines.push('Project: (not a git repository)'); return lines.join('\n'); }
  lines.push(`Project: ${ctx.project.name}  (${ctx.project.id}${ctx.created ? ' — registered just now, sidecar' : ''})`);
  lines.push(`Branch: ${ctx.identity.branch || '(detached)'}`);
  lines.push(`Brain: ${describeBrain(ctx.brain || { state: 'off' })}`);
  lines.push(`Agency: ${ctx.legacy ? 'ready (v2 personas)' : 'not configured'}`);
  lines.push('');
  lines.push(`Executor: ${ctx.executorId}${ctx.executor ? '' : '  (not registered)'}`);
  lines.push(`Authentication: ${ctx.executorAvailable ? 'subscription (local CLI found)' : `${ctx.executorId} CLI not found on PATH`}`);
  lines.push(`Controller: ${describeController(ctx)}`);
  const board = boardSnapshot(ctx);
  const tracker = ctx.legacy && ctx.identity ? localTracker(ctx) : null;
  if (tracker) {
    const st = readWorkflowState(tracker, ctx.legacy);
    if (st.awaiting_human.length) lines.push(`Awaiting you: ${st.gates.gate1.map((i) => `Gate 1 ${i.id}`).concat(st.gates.gate2.map((i) => `Gate 2 ${i.id}`), st.blocked.map((i) => `Blocked ${i.id}`), st.clarifying.map((i) => `Clarifying ${i.id}`)).join(' · ')}`);
  }
  const st = new StateRepo().status();
  if (st.initialized) lines.push(`State: ${st.head}${st.dirty ? ` (+${st.dirty} uncommitted)` : ''} · ${st.remote ? `remote ${st.remote}${st.ahead != null ? ` · ahead ${st.ahead} behind ${st.behind}` : ''}` : 'no remote (autodev state remote <url>)'}`);
  if (ctx.legacy) {
    const v = ctx.legacy.validation;
    const cfgNote = v && !v.ok ? ` · config: ${v.errors.length} error(s) — run \`autodev doctor\`` : (v?.warnings?.length ? ` · config: ${v.warnings.length} warning(s)` : '');
    const kind = ctx.legacy.sidecar ? 'sidecar deployment' : 'v2 deployment';
    lines.push(`Status: ready — ${kind} "${ctx.legacy.client_name}" · tracker ${ctx.legacy.tracker?.kind || 'local'}${ctx.project.tracker?.mode === 'sidecar' ? ' (sidecar board)' : ''} · planning ${ctx.legacy.planning?.engine || 'agency'}${board ? ` · board: ${board}` : ''}${cfgNote}`);
  } else lines.push('Status: registered (sidecar); not configured yet — run `autodev init` (writes nothing into the repo)');
  return lines.join('\n');
}

// ---- controller (Marj) ---------------------------------------------------------------
// The controller is resolved from deployment config (controller.*), overridable
// with AUTODEV_CONTROLLER=none for scripts. Unavailable ≠ broken: every
// deterministic command keeps working; only natural language needs Marj.
function controllerConfig(ctx, env = process.env) {
  const c = { name: 'marj', provider: 'claude-code', model: 'default', ...(ctx.legacy?.controller || {}) };
  if (env.AUTODEV_CONTROLLER) c.provider = env.AUTODEV_CONTROLLER;
  c.display = c.name.charAt(0).toUpperCase() + c.name.slice(1);
  return c;
}
async function attachController(ctx) {
  ctx.controller = controllerConfig(ctx);
  ctx.controllerImpl = null; ctx.controllerAvailable = false; ctx.controllerReason = null;
  if (ctx.controller.provider === 'none') { ctx.controllerReason = 'provider none (deterministic commands only)'; return ctx; }
  if (!hasController(ctx.controller.provider)) { ctx.controllerReason = `provider "${ctx.controller.provider}" not registered (available: ${listControllers().join(', ')})`; return ctx; }
  ctx.controllerImpl = ctx.controller.provider === 'claude-code' && ctx.controller.model && ctx.controller.model !== 'default' ? new ClaudeCodeController({ model: ctx.controller.model }) : getController(ctx.controller.provider);
  ctx.controllerAvailable = await ctx.controllerImpl.available();
  if (!ctx.controllerAvailable) ctx.controllerReason = `${ctx.controller.provider} CLI not found on PATH`;
  return ctx;
}
function describeController(ctx) {
  const c = ctx.controller || controllerConfig(ctx);
  return ctx.controllerAvailable ? `${c.display} (${c.provider}${c.model && c.model !== 'default' ? ` · ${c.model}` : ''}) — say what you want; deterministic commands bypass it` : `unavailable — ${ctx.controllerReason || 'not configured'}; deterministic commands only (help)`;
}
function session(ctx, actor) { return new ControlSession({ cwd: ctx.identity?.root || process.cwd(), actor: actor || { kind: 'cli', name: process.env.USER || 'operator' } }); }

// One conversational turn: input → intent (controller) → validated actions
// (Control API) → audit (deterministic) → explanation (controller, optional).
async function marjTurn(ctx, text, { history = [] } = {}) {
  const c = ctx.controller;
  if (!ctx.controllerAvailable) {
    if (c.provider === 'none') return runJob(ctx, text, 'concierge');   // explicit opt-out: the pre-Marj concierge path (runJob reports its own preconditions)
    console.error(`autodev: controller unavailable — ${ctx.controllerReason}. Deterministic commands still work: help`); return 1;
  }
  const t0 = Date.now();
  const s = session(ctx, { kind: 'controller', name: c.display, provider: c.provider, user: process.env.USER || 'operator' });
  const [status, blockers, projects] = await Promise.all([s.call('get_status'), s.call('get_blockers'), s.call('list_projects')]);
  let intent;
  try { intent = await ctx.controllerImpl.interpret({ text, name: c.display, user: process.env.USER || 'the developer', cwd: ctx.identity?.root, status: status.ok ? status.result : { error: status.error }, blockers: blockers.ok ? blockers.result : null, projects: projects.ok ? projects.result : null, history }); }
  catch (e) { if (e instanceof IntentError) { console.error(`${c.display}: ${e.message}`); return 1; } throw e; }
  console.log(`${c.display}: ${intent.goal || '(no goal stated)'}${intent.confidence != null && intent.confidence < 0.5 ? '  (low confidence)' : ''}`);
  for (const q of intent.questions) console.log(`${c.display} asks: ${q}`);
  if (!intent.steps.length) { appendControllerEvent(ctx, { text, intent, audit: null, ms: Date.now() - t0 }); return 0; }
  console.log(`plan: ${intent.steps.map((st) => st.action + (Object.keys(st.params).length ? ` ${JSON.stringify(st.params)}` : '')).join(' → ')}${Object.keys(intent.constraints).length ? `  [${Object.keys(intent.constraints).join(', ')}]` : ''}`);
  const audit = await executeIntent(intent, s, { log: (m) => console.error(m) });
  const rendered = renderAudit(audit);
  console.log(rendered);
  appendControllerEvent(ctx, { text, intent, audit, ms: Date.now() - t0 });
  if (process.env.AUTODEV_MARJ_EXPLAIN !== '0') { const said = await ctx.controllerImpl.respond({ name: c.display, text, intent, rendered, cwd: ctx.identity?.root }); if (said && said !== rendered) console.log(`${c.display}: ${said}`); }
  return audit.stopped ? 1 : 0;
}
function appendControllerEvent(ctx, { text, intent, audit, ms }) {
  if (!ctx.project) return;
  const acc = (audit?.steps || []).filter((s) => s.result?.ok).map((s) => s.action), rej = (audit?.steps || []).filter((s) => s.rejected || (s.result && !s.result.ok)).map((s) => s.action);
  try { appendEvent(ctx.project.id, { type: 'controller.turn', controller: ctx.controller.name, provider: ctx.controller.provider, model: ctx.controller.model, input: text.slice(0, 2000), intent: { goal: intent.goal, steps: intent.steps, constraints: intent.constraints, questions: intent.questions, confidence: intent.confidence }, accepted: acc, rejected: rej, jobs: (audit?.steps || []).map((s) => s.result?.result?.job_id).filter(Boolean), executor: ctx.executorId, stopped: audit?.stopped || null, ms }); } catch {}
}

function printResult(r, { pretty = true } = {}) {
  if (!r.ok) { console.error(`autodev: ${r.error.message}${r.error.code ? ` [${r.error.code}]` : ''}`); return 1; }
  const v = r.result;
  console.log(typeof v === 'string' ? v : JSON.stringify(v, null, pretty ? 2 : 0));
  return 0;
}
async function cmdControl(ctx, op, json) {
  if (!op || op === 'list') { for (const [k, d] of Object.entries(OPERATIONS)) console.log(`${k.padEnd(22)} ${d.reads ? 'read  ' : 'action'} ${d.description}`); return 0; }
  let params = {}; if (json) { try { params = JSON.parse(json); } catch { console.error('autodev: params must be JSON, e.g. \'{"id":"AD-3"}\''); return 2; } }
  return printResult(await session(ctx).call(op, params));
}
async function cmdMarj(ctx, sub) {
  const c = ctx.controller;
  switch (sub || 'status') {
    case 'status': console.log(`controller: ${c.display} · provider ${c.provider} · model ${c.model}\navailable: ${ctx.controllerAvailable ? 'yes' : `no — ${ctx.controllerReason}`}\ncapabilities: ${Object.keys(OPERATIONS).length} Control API operations (autodev control list)`); return 0;
    case 'contract': console.log(controllerContract({ name: c.display, user: process.env.USER || 'the developer' })); return 0;
    case 'setup': console.log(`Make a Claude Code session ${c.display} (bootstrap, PRD §32–34). Nothing is written into any repository.\n\n  1. once, user scope:   claude mcp add autodev -- autodev mcp\n  2. in any project:     claude      → the session sees the autoDev Control API tools + ${c.display}'s contract as server instructions\n  3. remote:             Claude Remote Control on the Mac mini steers that same session (autodev tick keeps running regardless)\n\nInside the session, \`${c.display}\` can only act through the Control API tools: reads are free, actions are validated and recorded by autoDev, human gates are never crossed without your explicit approve_gate.`); return 0;
    default: console.error('usage: autodev marj [status|contract|setup]'); return 2;
  }
}
async function cmdProjects() {
  const rows = await attentionAcrossProjects();
  if (!rows.length) { console.log('no projects registered on this machine'); return 0; }
  for (const p of rows) {
    if (!p.available) { console.log(`${p.name}: unavailable — ${p.reason}`); continue; }
    const need = p.awaiting_human.map((i) => `${i.id} (${i.stage})`).join(', ');
    console.log(`${p.name}${p.paused ? ' [paused]' : ''}: ${p.configured ? `${need ? `needs you: ${need}` : 'nothing waiting on you'} · in flight ${p.in_flight.length}${p.next ? ` · next ${p.next.action}` : ''}` : 'not configured (autodev init)'}`);
  }
  return 0;
}
async function cmdBlockers(ctx) {
  const r = await session(ctx).call('get_blockers'); if (!r.ok) return printResult(r);
  const b = r.result; const show = (label, arr) => { for (const i of arr) console.log(`${label} ${i.id} ${i.title}${i.why ? `\n    ${i.why.replace(/\n/g, ' ')}` : ''}`); };
  show('Gate 1  ', b.gate1); show('Gate 2  ', b.gate2); show('Blocked ', b.blocked); show('Clarify ', b.clarifying);
  if (![b.gate1, b.gate2, b.blocked, b.clarifying].some((a) => a.length)) console.log('nothing is waiting on you');
  if (b.paused) console.log(`project paused by ${b.paused.by} since ${b.paused.at}${b.paused.reason ? ` — ${b.paused.reason}` : ''}`);
  return 0;
}
async function cmdVerify(ctx, id) {
  const r = await session(ctx).call('run_verification', id ? { id } : {}); if (!r.ok) return printResult(r);
  const v = r.result;
  for (const [k, x] of Object.entries(v.results)) console.log(`${k}: ${x.skipped ? 'skipped (not configured)' : x.ok ? `✓ ${x.command}` : `✗ exit ${x.exit_code} — ${x.command}\n${x.tail}`}`);
  if (v.contamination.length) console.log(`contamination: ${v.contamination.join(', ')} present in a sidecar-mode repo`);
  console.log(`verification: ${v.ok ? 'PASS' : 'FAIL'} (${v.branch} @ ${v.head})`);
  return v.ok ? 0 : 1;
}

// ---- commands ---------------------------------------------------------------------
async function cmdStatus(ctx) { console.log(banner(ctx)); return 0; }

async function cmdExecutor(ctx, name) {
  if (!name) { console.log(`${ctx.executorId}  (available: ${listExecutors().join(', ')})`); return 0; }
  if (!hasExecutor(name)) { console.error(`autodev: no executor "${name}" registered (available: ${listExecutors().join(', ')})`); return 1; }
  if (!ctx.project) { console.error('autodev: not in a git repository'); return 1; }
  ctx.project.executor = { ...(ctx.project.executor || {}), default: name };
  saveProject(ctx.project);
  ctx.executorId = name; ctx.executor = getExecutor(name); ctx.executorAvailable = await ctx.executor.available();
  console.log(`executor: ${name}${ctx.executorAvailable ? '' : '  (warning: CLI not found on PATH)'}`);
  return 0;
}

async function runJob(ctx, task, role) {
  if (!ctx.identity) { console.error('autodev: not in a git repository'); return 1; }
  if (!ctx.executor) { console.error(`autodev: executor "${ctx.executorId}" is not registered`); return 1; }
  if (!ctx.legacy) { console.error('autodev: this repo has no autoDev deployment yet (no .autodev/deployment.json) — nothing to proxy to'); return 1; }
  const allow = assertAllowlistInvariants(headlessAllowlist(ctx.legacy), ctx.legacy);
  const job = makeJob({ role, task, cwd: ctx.identity.root, project_id: ctx.project.id, permissions: { allowed_tools: allow }, context: { branch: ctx.identity.branch } });
  const bc = await contextForJob(ctx.brain, ctx, { role, executor: ctx.executorId, branch: ctx.identity.branch, log: (m) => console.error(m) });
  if (bc) { job.context.brain = { bundle_id: bc.bundle.id, memories: bc.bundle.memories.map((m) => ({ id: m.id, revision: m.revision })) }; job.task = `${bc.text}\n\n---\n\n${job.task}`; }
  const r = await ctx.executor.execute(job);
  await recordHandoff(ctx.brain, ctx, job, r, { log: (m) => console.error(m) });
  if (r.status === 'completed') { console.log(r.summary || '(no output)'); return 0; }
  console.error(`autodev: ${ctx.executorId} → ${r.status}${r.summary ? `: ${r.summary}` : ''}${r.reset_at ? ` (reset ${new Date(r.reset_at * 1000).toLocaleTimeString()})` : ''}`);
  return r.status === 'rate_limited' ? 75 : 1;
}

function localTracker(ctx) {
  if (!ctx.legacy || (ctx.legacy.tracker?.kind || 'local') !== 'local') return null;
  return Tracker.for(ctx);
}

async function cmdNext(ctx) {
  const tracker = localTracker(ctx);
  if (!tracker) { console.error('autodev: next needs a local-tracker deployment (API trackers are read through the engine for now)'); return 1; }
  const state = readWorkflowState(tracker, ctx.legacy);
  const n = nextAction(state, ctx.legacy);
  console.log(describeState(state, ctx.legacy));
  console.log(`\nnext: ${n.action}${n.issues?.length ? ` (${n.issues.join(', ')})` : ''} — ${n.reason}`);
  return 0;
}

// Gate decisions: deterministic on a local board (record → bounded job → verify);
// proxied to the prose engine for API trackers until their core wrapper lands.
function claimSeat(ctx) {
  try { new StateRepo().claim(ctx.project.id); return true; }
  catch (e) { if (e instanceof StateError) { console.error(`autodev: ${e.message}`); return false; } throw e; }
}

async function cmdApprove(ctx, id, note) {
  if (!id) { console.error('usage: autodev approve <issue-id> [note]'); return 2; }
  if (!claimSeat(ctx)) return 1;
  const tracker = localTracker(ctx);
  if (!tracker) return runJob(ctx, `The operator approved ${id}${note ? ` — ${note}` : ''}. Log the gate decision with an audit comment and advance it per the manual; do one bounded unit of work then stop.`, 'gate');
  let decision;
  try { decision = gateApprove({ tracker, projectId: ctx.project.id, issueId: id, by: process.env.USER, note }); }
  catch (e) { if (e instanceof GateError) { console.error(`autodev: ${e.message}`); return 1; } throw e; }
  console.log(`recorded: Gate ${decision.gate} approved for ${decision.issue}${decision.moved ? ` → ${decision.moved}` : ''} (event ${decision.event.id})`);
  await recordGateDecision(ctx.brain, ctx, decision, { log: (m) => console.error(m) });
  const job = jobFor(decision.next, decision.issue, ctx.legacy);
  console.log(`job → ${ctx.executorId}: ${decision.next} (${job.role})`);
  const rc = await runJob(ctx, job.task, job.role);
  const after = tracker.issue(decision.issue);
  const expect = decision.next === 'breakdown' ? null : 'done';
  if (expect && after?.stage !== expect) console.error(`verify: ${decision.issue} is in "${after?.stage}", expected "${expect}" — the merge did not complete; see the board comments`);
  else if (decision.next === 'breakdown') {
    const state = readWorkflowState(tracker, ctx.legacy);
    console.log(`verify: ${state.eligible.length} story(ies) now Ready for AI Dev · ${decision.issue} in "${after?.stage}"`);
  } else console.log(`verify: ${decision.issue} is done`);
  return rc;
}

async function cmdReject(ctx, id, reason) {
  if (!id || !reason) { console.error('usage: autodev reject <issue-id> <reason>'); return 2; }
  const tracker = localTracker(ctx);
  if (!tracker) return runJob(ctx, `The operator rejected ${id} at its gate: ${reason}. Log the decision with an audit comment and move it back per the manual; do one bounded unit of work then stop.`, 'gate');
  try {
    const d = gateReject({ tracker, projectId: ctx.project.id, issueId: id, by: process.env.USER, reason });
    console.log(`recorded: Gate ${d.gate} rejected for ${d.issue}${d.moved ? ` → ${d.moved}` : ''} (event ${d.event.id})`);
    await recordGateDecision(ctx.brain, ctx, d, { log: (m) => console.error(m) });
    return 0;
  } catch (e) { if (e instanceof GateError) { console.error(`autodev: ${e.message}`); return 1; } throw e; }
}

async function cmdTick(repo, log) {
  if (!repo) { console.error('usage: autodev tick <repo-path>'); return 2; }
  try { return await tick(repo, { log }); }
  catch (e) {
    if (e.code === 'NO_CONFIG' || e.code === 'INVALID_CONFIG') { console.error(`autodev tick: ${e.message}`); return 1; }
    throw e;
  }
}

// v3 init: a deployment for THIS project written into the sidecar — the repo stays
// byte-identical (G9). Detects what it can; flags override; no questions (interactive
// setup stays in the plugin's /autodev:init for now).
async function cmdInit(ctx, args) {
  if (!ctx.identity) { console.error('autodev: not in a git repository'); return 1; }
  if (ctx.legacy && !ctx.legacy.sidecar) { console.error(`autodev: this repo already has a v2 deployment at ${ctx.legacy.configPath} — v3 keeps using it; migrate with \`autodev migrate\` (M14)`); return 1; }
  const f = {}; for (let i = 0; i < args.length; i++) if (args[i].startsWith('--')) { f[args[i].slice(2)] = args[i + 1] && !args[i + 1].startsWith('--') ? args[++i] : true; }
  const dest = projectDeploymentFile(ctx.project.id);
  if (existsSync(dest) && !f.force) { console.error(`autodev: already initialized (${dest}) — pass --force to rewrite with detected values`); return 1; }
  const cfg = schemaDefaults({ identity: true, local: false });
  const root = ctx.identity.root;
  cfg.client_name = f.name || ctx.project.name;
  cfg.assistant_name = f.assistant || 'Marj';
  cfg.repo = { url: ctx.identity.remote_raw || '', default_branch: f['default-branch'] || ctx.identity.branch || 'main', feature_branch_prefix: 'feature/', story_branch_prefix: 'autodev' };
  cfg.bot_identity = { name: 'autodev-bot', email: 'autodev-bot@example.com' };
  cfg.tracker.kind = 'local'; cfg.tracker.instance_label = `autodev:${cfg.client_name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')}`;
  // detect commands from package.json scripts (bun/pnpm/yarn/npm)
  const pm = existsSync(join(root, 'bun.lockb')) || existsSync(join(root, 'bun.lock')) ? 'bun' : existsSync(join(root, 'pnpm-lock.yaml')) ? 'pnpm' : existsSync(join(root, 'yarn.lock')) ? 'yarn' : 'npm';
  let scripts = {}; try { scripts = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).scripts || {}; } catch {}
  const run = (k) => (scripts[k] ? (pm === 'npm' ? `npm run ${k}` : `${pm} ${k}`) : '');
  cfg.commands = { install: f.install ?? (existsSync(join(root, 'package.json')) ? `${pm} install` : ''), test: f.test ?? (scripts.test ? (pm === 'npm' ? 'npm test' : `${pm} test`) : ''), lint: f.lint ?? run('lint'), build: f.build ?? run('build'), app_run: f.run ?? (run('dev') || run('start') || run('serve')), app_url: f.url ?? (scripts.dev || scripts.start ? 'http://localhost:3000' : '') };
  cfg.qa.hermetic.env = {}; cfg.qa.hermetic.forbid_endpoints = []; cfg.qa.acceptance.integrated_suites = cfg.commands.test ? [cfg.commands.test] : []; cfg.qa.e2e_framework = ''; cfg.qa.e2e_dir = '';
  cfg.personas.dev_routing = [{ match: 'default', persona: 'general-purpose', why: 'fallback when no clear specialist' }];
  cfg.brain = { enabled: !!f['brain-url'], project_id: null, url: f['brain-url'] || null };
  const v = validateConfig(cfg);
  if (!v.ok) { console.error(`autodev: generated config is invalid:\n  - ${v.errors.join('\n  - ')}`); return 1; }
  ensureProjectDirs(ctx.project.id); mkdirSync(projectBoardDir(ctx.project.id), { recursive: true });
  writeFileSync(dest, JSON.stringify(cfg, null, 2) + '\n');
  ctx.project.tracker = { kind: 'local', location: projectBoardDir(ctx.project.id), mode: 'sidecar' };
  saveProject(ctx.project, undefined, { commit: false });
  new StateRepo().commit(`project ${ctx.project.id}: initialized ${cfg.client_name}`);
  console.log(`initialized ${cfg.client_name} (sidecar)\n  deployment: ${dest}\n  board:      ${projectBoardDir(ctx.project.id)}\n  commands:   test "${cfg.commands.test || '—'}" · lint "${cfg.commands.lint || '—'}" · build "${cfg.commands.build || '—'}" · run "${cfg.commands.app_run || '—'}"\n  nothing was written into ${root}\nnext: autodev status · autodev state remote <url> (Mac mini) · edit the deployment file for hermetic env + routing`);
  return 0;
}

// autodev migrate [--from claude] [--dry-run] [--import-user]
async function cmdMigrate(ctx, args) {
  if (!ctx.identity) { console.error('autodev: not in a git repository'); return 1; }
  const f = {}; for (let i = 0; i < args.length; i++) if (args[i].startsWith('--')) { f[args[i].slice(2)] = args[i + 1] && !args[i + 1].startsWith('--') ? args[++i] : true; }
  if (f.from && f.from !== 'claude') { console.error(`autodev: only --from claude is supported`); return 2; }
  const p = migratePlan(ctx);
  if (f['dry-run']) { console.log(renderReport(p)); return 0; }
  const r = await migrateApply(ctx, p, { brain: ctx.brain, importUser: !!f['import-user'], log: (m) => console.error(m) });
  console.log(readFileSync(r.report, 'utf8'));
  console.log(`report: ${r.report}`);
  return r.sidecar.some((s) => s.valid === false) ? 1 : 0;
}

async function cmdState(ctx, sub, arg) {
  const st = new StateRepo();
  switch (sub || 'status') {
    case 'status': { const s = st.status(); if (!s.initialized) { console.log('state: not initialized (created on first registration)'); return 0; } console.log(`state: ${s.dir}\n  head ${s.head} · ${s.dirty} uncommitted · machine ${s.machine}\n  remote ${s.remote || '(none) — autodev state remote <url>'}${s.ahead != null ? ` · ahead ${s.ahead} · behind ${s.behind}` : ''}`); if (ctx.project) { const w = st.writer(ctx.project.id); console.log(`  writer for ${ctx.project.id}: ${w ? `${w.machine} since ${w.since}` : '(none)'}`); } return 0; }
    case 'remote': { if (!arg) { console.log(st.remote() || '(none)'); return 0; } st.setRemote(arg); console.log(`remote: ${arg}\nnext: autodev state sync   (on the Mac mini once: git init --bare -b main "~/Library/Application Support/autoDev/state.git")`); return 0; }
    case 'sync': { st.init(); st.commit('state: sync'); const r = st.sync(); console.log(`pull: ${r.pull.pulled ? (r.pull.changed ? `fast-forwarded to ${r.pull.to}` : 'up to date') : r.pull.reason}\npush: ${r.push.pushed ? 'ok' : r.push.reason}`); return r.ok ? 0 : 1; }
    case 'takeover': { if (!ctx.project) { console.error('autodev: not in a git repository'); return 1; } const p = st.pull(); if (p.diverged) { console.error(`autodev: ${p.reason}`); return 1; } const seat = st.claim(ctx.project.id, { takeover: true }); st.commit(`state: ${seat.machine} took over ${ctx.project.id}${seat.took_over_from ? ` from ${seat.took_over_from}` : ''}`); const r = st.push(); console.log(`writer: ${seat.machine}${seat.took_over_from ? ` (took over from ${seat.took_over_from})` : ''} · push ${r.pushed ? 'ok' : r.reason}`); return 0; }
    case 'release': { if (!ctx.project) return 1; st.release(ctx.project.id); st.commit(`state: released ${ctx.project.id}`); st.push(); console.log('writer seat released'); return 0; }
    default: console.error(`autodev: unknown state subcommand "${sub}" (status | remote [url] | sync | takeover | release)`); return 2;
  }
}

async function cmdAgents(ctx, sub) {
  const cfg = ctx.legacy || {};
  ensureAgentsDirs();
  const store = new PersonaStore();
  const target = claudeAgentsDir();
  // first contact: an empty store next to a populated executor dir means this machine
  // predates the store — adopt (copy, never move or overwrite) before reporting
  if (!store.list().length) { const got = store.importFrom(target); if (got.length) console.error(`agency: adopted ${got.length} persona(s) from ${target} into the store (one-time)`); }
  if (sub === 'sync') {
    const imported = store.importFrom(target);
    const proj = projectPersonas(cfg, store, { targetDir: target });
    console.log(`agency store: ${store.dir}`);
    console.log(`adopted from ${target}: ${imported.length ? (imported.length <= 10 ? imported.join(', ') : `${imported.length} files`) : 'nothing new'}`);
    console.log(`projected → ${target}: ${proj.written.length} written · ${proj.updated.length} updated · ${proj.kept.length} kept · ${proj.missing.length} missing${proj.missing.length ? ` (${proj.missing.join(', ')})` : ''}`);
    return 0;
  }
  if (sub === 'install') {
    const r = await ensurePersonas(cfg, { store });
    for (const x of r.report) console.log(`  ${x.status === 'unresolved' || x.status === 'invalid' ? '✗' : x.status === 'downloaded' ? '⬇' : '✓'} ${x.slug} ${x.status}${x.reason ? ` (${x.reason})` : ''}`);
    console.log(`personas: ${r.needed} needed · ${r.installed} installed · ${r.downloaded} downloaded · ${r.unresolved} unresolved${r.unresolved ? ` (→ ${r.fallback})` : ''}`);
    return r.unresolved ? 1 : 0;
  }
  const roles = loadRoles({ cfg });
  console.log(`Agency — ${roles.length} model-neutral roles (store: ${store.dir})`);
  for (const r of roles) {
    const res = r.personas.map((p) => `${p}${p === 'general-purpose' ? '' : store.has(p) ? '' : ' (not installed → ' + r.fallback + ')'}`).join(', ');
    console.log(`  ${r.id.padEnd(16)} ${r.name.padEnd(24)} persona: ${res}${r.overridden ? '  [overridden]' : ''}`);
  }
  return 0;
}

async function cmdBrain(ctx, sub, arg) {
  const b = ctx.brain || { state: 'off' };
  if (!sub || sub === 'status') { console.log(`Brain: ${describeBrain(b)}${b.token_source ? ` · token from ${b.token_source}` : ''}${b.capabilities ? ` · caps ${b.capabilities.join(',')}` : ''}`); return b.state === 'connected' || b.state === 'off' ? 0 : 1; }
  if (b.state !== 'connected') { console.error(`autodev: Brain is ${describeBrain(b)}`); return 1; }
  if (sub === 'context') { const c = await contextForJob(b, ctx, { role: 'operator', executor: 'cli', branch: ctx.identity?.branch, requirement_key: arg }); if (!c) { console.error('autodev: no context (project not registered?)'); return 1; } console.log(c.text); return 0; }
  if (sub === 'search') { if (!arg) { console.error('usage: autodev brain search <query>'); return 2; } const rows = await b.client.search({ q: arg, project_id: b.project_id }); if (!rows.length) { console.log('(no matches in scope)'); return 0; } for (const m of rows) console.log(`${m.id}  [${m.scope.type}] ${m.state}/${m.type}: ${m.content.slice(0, 120)}`); return 0; }
  if (sub === 'remember') { if (!arg) { console.error('usage: autodev brain remember <content>'); return 2; } const m = await b.client.remember({ project_id: b.project_id, content: arg, provenance: [{ type: 'human_decision', source: process.env.USER || 'operator' }] }); console.log(`${m.id} [${m.scope.type}] ${m.state}`); return 0; }
  console.error(`autodev: unknown brain subcommand "${sub}" (status | context [REQ] | search <q> | remember <text>)`); return 2;
}

function cmdDoctor(cwd) {
  const r = spawnSync('bash', [join(ROOT, 'scripts', 'doctor.sh')], { cwd, stdio: 'inherit' });
  return r.status ?? 1;
}

// ---- dispatch ---------------------------------------------------------------------
// `parts` is argv (quoting preserved) or a shell line split on whitespace
async function dispatch(ctx, parts) {
  const words = Array.isArray(parts) ? parts : String(parts).trim().split(/\s+/);
  const [cmd, ...rest] = words;
  const line = words.join(' ');
  switch ((cmd || '').toLowerCase()) {
    case '': return 0;
    case 'help': case '?': console.log(HELP); return 0;
    case 'version': case '--version': case '-v': console.log(VERSION); return 0;
    case 'status': return cmdStatus(ctx);
    case 'executor': return cmdExecutor(ctx, rest[0]);
    case 'continue': case 'loop': return rest[0] ? printResult(await session(ctx).call('continue_requirement', { id: rest[0], instructions: rest.slice(1).join(' ') || undefined })) : runJob(ctx, '/autodev:loop', 'loop');
    case 'mcp': return serveMcp({ cwd: ctx.identity?.root || process.cwd(), name: ctx.controller.display, user: process.env.USER || 'the developer', version: VERSION }).then(() => 0);
    case 'marj': return cmdMarj(ctx, rest[0]);
    case 'control': return cmdControl(ctx, rest[0], rest.slice(1).join(' ') || undefined);
    case 'projects': case 'attention': return cmdProjects();
    case 'blockers': return cmdBlockers(ctx);
    case 'new': return rest.length ? printResult(await session(ctx).call('start_requirement', { title: rest.join(' ') })) : (console.error('usage: autodev new <title>'), 2);
    case 'review': return rest[0] ? printResult(await session(ctx).call('request_review', { id: rest[0] })) : (console.error('usage: autodev review <id>'), 2);
    case 'verify': return cmdVerify(ctx, rest[0]);
    case 'diff': return printResult(await session(ctx).call('get_diff_summary', { branch: rest[0], base: rest[1] }));
    case 'pause': return printResult(await session(ctx).call('pause_requirement', /^[A-Za-z]+-\d+$/.test(rest[0] || '') ? { id: rest[0], reason: rest.slice(1).join(' ') || undefined } : { reason: rest.join(' ') || undefined }));
    case 'resume': return printResult(await session(ctx).call('resume_requirement', rest[0] ? { id: rest[0] } : {}));
    case 'approve': return cmdApprove(ctx, rest[0], rest.slice(1).join(' ') || undefined);
    case 'reject': return cmdReject(ctx, rest[0], rest.slice(1).join(' ') || undefined);
    case 'next': return cmdNext(ctx);
    case 'doctor': return cmdDoctor(ctx.identity?.root || process.cwd());
    case 'agents': return cmdAgents(ctx, rest[0]);
    case 'init': return cmdInit(ctx, rest);
    case 'migrate': return cmdMigrate(ctx, rest);
    case 'state': return cmdState(ctx, rest[0], rest[1]);
    case 'brain': return cmdBrain(ctx, rest[0], rest.slice(1).join(' ') || undefined);
    case 'tick': return cmdTick(rest[0], (m) => console.log(m));
    default: return marjTurn(ctx, line.trim(), { history: ctx.history || [] });
  }
}

async function shell(ctx) {
  console.log(banner(ctx));
  console.log('');
  const rl = createInterface({ input: process.stdin, output: process.stdout, prompt: `${ctx.controllerAvailable ? ctx.controller.display : 'autodev'} > `, terminal: process.stdin.isTTY === true });
  rl.prompt();
  let last = 0; ctx.history = [];
  for await (const line of rl) {
    const t = line.trim().toLowerCase();
    if (t === 'exit' || t === 'quit' || t === 'q') break;
    try { last = await dispatch(ctx, line); } catch (e) { console.error(`autodev: ${e.message}`); last = 1; }
    if (line.trim()) { ctx.history.push({ role: 'user', text: line.trim().slice(0, 500) }); ctx.history = ctx.history.slice(-12); }
    rl.prompt();
  }
  rl.close();
  return last;
}

export async function main(argv) {
  const [cmd] = argv;
  if (cmd === 'help' || cmd === '--help' || cmd === '-h') { console.log(HELP); return 0; }
  if (cmd === 'version' || cmd === '--version' || cmd === '-v') { console.log(VERSION); return 0; }
  if (cmd === 'tick') return cmdTick(argv[1], (m) => console.error(m));
  const ctx = await attachController(await context(process.cwd()));
  if (!cmd) return shell(ctx);
  return dispatch(ctx, argv);
}
