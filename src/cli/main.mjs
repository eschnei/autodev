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
import { defaults as schemaDefaults, validate as validateConfig } from '../core/config/schema.mjs';
import { projectDeploymentFile, projectBoardDir, ensureProjectDirs } from '../core/paths.mjs';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { headlessAllowlist, assertAllowlistInvariants } from '../core/permissions.mjs';
import { tick } from '../core/tick.mjs';
import { makeJob, getExecutor, listExecutors, hasExecutor } from '../executors/executor.mjs';
import '../executors/claude/index.mjs';

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
  state [status|remote <url>|sync|takeover|release]   the sidecar state repo (workflow reality) + its private remote
  brain [status|context [REQ]|search <q>|remember <text>]   the Brain connection (optional; degraded mode when unreachable)
  agents [sync|install]  Agency roles + persona resolution; sync = adopt existing
                         ~/.claude/agents personas into the store and project the
                         store back out; install = fetch missing (consent-gated)
  doctor                 preflight the deployment (scripts/doctor.sh)
  version | help
  <anything else>        natural language, one shot, through the executor

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
    case 'continue': case 'loop': return runJob(ctx, '/autodev:loop', 'loop');
    case 'approve': return cmdApprove(ctx, rest[0], rest.slice(1).join(' ') || undefined);
    case 'reject': return cmdReject(ctx, rest[0], rest.slice(1).join(' ') || undefined);
    case 'next': return cmdNext(ctx);
    case 'doctor': return cmdDoctor(ctx.identity?.root || process.cwd());
    case 'agents': return cmdAgents(ctx, rest[0]);
    case 'init': return cmdInit(ctx, rest);
    case 'state': return cmdState(ctx, rest[0], rest[1]);
    case 'brain': return cmdBrain(ctx, rest[0], rest.slice(1).join(' ') || undefined);
    case 'tick': return cmdTick(rest[0], (m) => console.log(m));
    default: return runJob(ctx, line.trim(), 'concierge');
  }
}

async function shell(ctx) {
  console.log(banner(ctx));
  console.log('');
  const rl = createInterface({ input: process.stdin, output: process.stdout, prompt: '> ', terminal: process.stdin.isTTY === true });
  rl.prompt();
  let last = 0;
  for await (const line of rl) {
    const t = line.trim().toLowerCase();
    if (t === 'exit' || t === 'quit' || t === 'q') break;
    try { last = await dispatch(ctx, line); } catch (e) { console.error(`autodev: ${e.message}`); last = 1; }
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
  const ctx = await context(process.cwd());
  if (!cmd) return shell(ctx);
  return dispatch(ctx, argv);
}
