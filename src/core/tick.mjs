// autoDev — one headless heartbeat tick (Milestone 3: the runner goes through the
// Executor seam). This is the body that used to live in scripts/devloop-tick.sh;
// the shell script is now a thin launchd-facing wrapper that delegates here.
//
//   autoDev core (this file)
//       ↓ Job { task: "/autodev:loop", permissions: allowlist }
//   Executor.execute()
//       ↓
//   ClaudeCodeExecutor  → claude CLI      (src/executors/claude/index.mjs)
//
// Observable contract (pinned by tests/suite/runner.sh, unchanged from the bash):
//   - stateless; all real state is on the board + git
//   - single-flight lock at <runner.home_dir>/devloop.lock; a dead PID's lock is taken
//   - heartbeat touched every tick, even while paused
//   - usage limit → <runner.home_dir>/rate-limited-until (+ board notice); while paused
//     each tick PROBES and resumes within one tick of the limit lifting, running the
//     full tick in the same pass
//   - result appended to <runner.home_dir>/logs/<YYYY-MM-DD>.jsonl, stderr to err.log
//   - digest (report.mjs) and Linear mirror flush run after, off the critical path

import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync, unlinkSync, utimesSync, closeSync, openSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { headlessAllowlist, assertAllowlistInvariants } from './permissions.mjs';
import { loadDeployment } from './config/index.mjs';
import { makeJob, getExecutor } from '../executors/executor.mjs';
import '../executors/claude/index.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SCRIPTS = join(ROOT, 'scripts');

function touch(p) { try { const t = new Date(); utimesSync(p, t, t); } catch { closeSync(openSync(p, 'a')); } }
function pidAlive(pid) { if (!pid) return false; try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } }
function today() { return new Date().toISOString().slice(0, 10); }

// Schema-validated, legacy-normalized config (src/core/config). NO_CONFIG /
// INVALID_CONFIG surface as ConfigError codes for the wrapper to report loudly.
export async function loadRepoConfig(repo) {
  const { cfg, configPath } = await loadDeployment(repo);
  return { cfg, configPath };
}

export function runnerHome(cfg) {
  return String(cfg.runner?.home_dir || '~/.autodev').replace(/^~/, homedir());
}

function notify(repo, kind, arg, runHome) {
  const r = spawnSync('bash', [join(SCRIPTS, 'notify.sh'), repo, kind, ...(arg == null ? [] : [String(arg)])], { encoding: 'utf8' });
  if (r.status !== 0) appendFileSync(join(runHome, 'logs', 'err.log'), `notify ${kind}: ${r.stderr || r.stdout}\n`);
}

// Runs one tick. Returns an exit code. `log` receives human-readable lines (the
// wrapper prints nothing; the CLI's interactive `continue` shows them).
export async function tick(repo, { executorId, log = () => {}, env = process.env } = {}) {
  const { cfg, configPath } = await loadRepoConfig(repo);
  const runHome = runnerHome(cfg);
  mkdirSync(join(runHome, 'logs'), { recursive: true });
  const errLog = join(runHome, 'logs', 'err.log');

  // --- single-flight lock (portable: macOS has no flock) ---
  const lock = join(runHome, 'devloop.lock');
  if (existsSync(lock)) {
    const pid = Number(readFileSync(lock, 'utf8').trim());
    if (pidAlive(pid) && pid !== process.pid) { log(`tick: previous tick (pid ${pid}) still running — skipped`); return 0; }
  }
  writeFileSync(lock, String(process.pid));
  const release = () => { try { if (existsSync(lock) && Number(readFileSync(lock, 'utf8').trim()) === process.pid) unlinkSync(lock); } catch {} };
  process.once('exit', release);
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.once(sig, () => { release(); process.exit(130); });

  try {
    touch(join(runHome, 'heartbeat'));
    const executor = getExecutor(executorId || cfg.executor?.default || 'claude');

    // --- rate-limit gate: while paused, PROBE instead of trusting a recorded reset time ---
    const pause = join(runHome, 'rate-limited-until');
    if (existsSync(pause)) {
      const lifted = await executor.probe?.() ?? false;
      if (lifted) {
        unlinkSync(pause);
        notify(repo, 'resumed', null, runHome);
        log('tick: rate limit lifted — resuming');
      } else {
        touch(pause);
        log('tick: still rate-limited — probed, waiting');
        return 0;
      }
    }

    // --- the bounded unit of work, through the executor seam ---
    const allow = assertAllowlistInvariants(headlessAllowlist(cfg), cfg);
    const job = makeJob({ role: 'loop', task: '/autodev:loop', cwd: repo, permissions: { allowed_tools: allow }, context: { config: configPath } });
    log(`tick: ${executor.id} ← ${job.task} (${allow.length} permissions)`);
    const result = await executor.execute(job);

    if (result.stderr) appendFileSync(errLog, `${result.stderr}\n`);
    appendFileSync(join(runHome, 'logs', `${today()}.jsonl`),
      (result.raw ? JSON.stringify(result.raw) : JSON.stringify({ status: result.status, summary: result.summary, job_id: job.job_id, executor: result.executor })) + '\n');

    if (result.status === 'rate_limited') {
      writeFileSync(pause, String(result.reset_at ?? 'unknown'));
      notify(repo, 'limited', result.reset_at ?? '', runHome);
      log(`tick: usage limit hit — paused (reset ${result.reset_at ?? 'unknown'})`);
    } else {
      log(`tick: ${result.status}${result.summary ? ` — ${result.summary.slice(0, 200)}` : ''}`);
    }

    // --- operator digest (self-gates on reporting.cadence) + Linear mirror flush (self-gates) ---
    for (const [script, args] of [[join(SCRIPTS, 'report.mjs'), []], [join(SCRIPTS, 'tracker.mjs'), ['flush-mirror']]]) {
      const r = spawnSync('node', [script, ...args], { cwd: repo, env: { ...env, AUTODEV_CONFIG: configPath }, encoding: 'utf8' });
      if (r.status !== 0) appendFileSync(errLog, `${script}: ${r.stderr}\n`);
    }
    return 0;
  } finally {
    release();
  }
}
