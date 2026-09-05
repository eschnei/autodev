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
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { resolveProject, saveProject } from '../core/project.mjs';
import { Tracker } from '../core/tracker.mjs';
import { loadRoles } from '../agency/roles.mjs';
import { PersonaStore, ensurePersonas } from '../agency/personas.mjs';
import { ensureAgentsDirs } from '../core/paths.mjs';
import { projectPersonas, claudeAgentsDir } from '../executors/claude/agents.mjs';
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
  approve <id> [note]    record a human gate decision (proxied to the engine in v3.0)
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
  return ctx;
}

function boardSnapshot(ctx) {
  if (!ctx.legacy || (ctx.legacy.tracker?.kind || 'local') !== 'local') return null;
  const tracker = new Tracker({ repoRoot: ctx.identity.root, configPath: ctx.legacy.configPath, cfg: ctx.legacy });
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
  lines.push(`Brain: ${ctx.project.brain?.enabled ? ctx.project.brain.url : 'not configured'}`);
  lines.push(`Agency: ${ctx.legacy ? 'ready (v2 personas)' : 'not configured'}`);
  lines.push('');
  lines.push(`Executor: ${ctx.executorId}${ctx.executor ? '' : '  (not registered)'}`);
  lines.push(`Authentication: ${ctx.executorAvailable ? 'subscription (local CLI found)' : `${ctx.executorId} CLI not found on PATH`}`);
  const board = boardSnapshot(ctx);
  if (ctx.legacy) {
    const v = ctx.legacy.validation;
    const cfgNote = v && !v.ok ? ` · config: ${v.errors.length} error(s) — run \`autodev doctor\`` : (v?.warnings?.length ? ` · config: ${v.warnings.length} warning(s)` : '');
    lines.push(`Status: ready — v2 deployment "${ctx.legacy.client_name}" · tracker ${ctx.legacy.tracker?.kind || 'local'} · planning ${ctx.legacy.planning?.engine || 'agency'}${board ? ` · board: ${board}` : ''}${cfgNote}`);
  } else lines.push('Status: registered (sidecar); no v2 deployment here — run /autodev:init in Claude Code until v3 init lands (M5A)');
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
  const job = makeJob({ role, task, cwd: ctx.identity.root, project_id: ctx.project.id, permissions: { allowed_tools: allow } });
  const r = await ctx.executor.execute(job);
  if (r.status === 'completed') { console.log(r.summary || '(no output)'); return 0; }
  console.error(`autodev: ${ctx.executorId} → ${r.status}${r.summary ? `: ${r.summary}` : ''}${r.reset_at ? ` (reset ${new Date(r.reset_at * 1000).toLocaleTimeString()})` : ''}`);
  return r.status === 'rate_limited' ? 75 : 1;
}

async function cmdTick(repo, log) {
  if (!repo) { console.error('usage: autodev tick <repo-path>'); return 2; }
  try { return await tick(repo, { log }); }
  catch (e) {
    if (e.code === 'NO_CONFIG' || e.code === 'INVALID_CONFIG') { console.error(`autodev tick: ${e.message}`); return 1; }
    throw e;
  }
}

async function cmdAgents(ctx, sub) {
  const cfg = ctx.legacy || {};
  ensureAgentsDirs();
  const store = new PersonaStore();
  const target = claudeAgentsDir();
  if (sub === 'sync') {
    const imported = store.importFrom(target);
    const proj = projectPersonas(cfg, store, { targetDir: target });
    console.log(`agency store: ${store.dir}`);
    console.log(`adopted from ${target}: ${imported.length ? imported.join(', ') : 'nothing new'}`);
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

function cmdDoctor(cwd) {
  const r = spawnSync('bash', [join(ROOT, 'scripts', 'doctor.sh')], { cwd, stdio: 'inherit' });
  return r.status ?? 1;
}

// ---- dispatch ---------------------------------------------------------------------
async function dispatch(ctx, line) {
  const [cmd, ...rest] = line.trim().split(/\s+/);
  const arg = rest.join(' ');
  switch ((cmd || '').toLowerCase()) {
    case '': return 0;
    case 'help': case '?': console.log(HELP); return 0;
    case 'version': case '--version': case '-v': console.log(VERSION); return 0;
    case 'status': return cmdStatus(ctx);
    case 'executor': return cmdExecutor(ctx, rest[0]);
    case 'continue': case 'loop': return runJob(ctx, '/autodev:loop', 'loop');
    case 'approve': return runJob(ctx, `The operator approved ${rest[0] || 'the pending gate'}${rest.length > 1 ? ` — ${rest.slice(1).join(' ')}` : ''}. Log the gate decision with an audit comment and advance it per the manual; do one bounded unit of work then stop.`, 'gate');
    case 'doctor': return cmdDoctor(ctx.identity?.root || process.cwd());
    case 'agents': return cmdAgents(ctx, rest[0]);
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
  return dispatch(ctx, argv.join(' '));
}
