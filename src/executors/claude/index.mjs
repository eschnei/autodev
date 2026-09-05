// autoDev — ClaudeCodeExecutor. THE ONLY place in the codebase that invokes the
// `claude` CLI (Milestone 3 acceptance: no `claude -p` anywhere in core/cli).
//
// Subscription-native: shells out to the user's authenticated Claude Code CLI, so
// their existing subscription is used. No credential ever passes through autoDev.
// A Job's permissions.allowed_tools become `--allowedTools` flags; the vendor JSON
// result is translated into the normalized ExecutionResult and never leaks past
// this file.

import { spawn, spawnSync } from 'node:child_process';
import { emptyResult, registerExecutor } from '../executor.mjs';

const USAGE_LIMIT_RE = /usage limit|rate limit/i;

export class ClaudeCodeExecutor {
  id = 'claude';
  #bin;
  #running = new Map(); // job_id → ChildProcess

  constructor({ bin = 'claude' } = {}) { this.#bin = bin; }

  async available() {
    const r = process.platform === 'win32'
      ? spawnSync('where', [this.#bin], { encoding: 'utf8' })
      : spawnSync('/bin/sh', ['-c', 'command -v -- "$0"', this.#bin], { encoding: 'utf8' });
    return r.status === 0;
  }

  async capabilities() {
    return {
      id: this.id,
      auth: 'subscription',                 // Claude Code CLI login; never an API key here
      streaming: false,
      tool_allowlist: true,                 // --allowedTools
      cancel: true,
      usage: false,                         // not observable through the CLI today
      executes_commands: 'via_allowlist',
    };
  }

  // Cheap liveness/rate-limit probe: a refused call returns instantly, a success
  // is ground truth the limit lifted (devloop-tick's probe-while-paused rule).
  async probe() {
    const r = await this.execute({ job_id: `probe_${Date.now()}`, task: 'reply with exactly: ok', permissions: { allowed_tools: [] }, cwd: process.cwd() });
    return r.status === 'completed';
  }

  execute(job) {
    const args = ['-p', job.task, '--output-format', 'json'];
    for (const t of job.permissions?.allowed_tools || []) args.push('--allowedTools', t);
    const started = new Date().toISOString();
    return new Promise((resolve) => {
      let out = '', err = '';
      let child;
      try {
        child = spawn(this.#bin, args, { cwd: job.cwd || process.cwd(), env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
      } catch (e) {
        return resolve(emptyResult(this.id, 'unavailable', { summary: String(e.message), started_at: started }));
      }
      this.#running.set(job.job_id, child);
      child.stdout.on('data', (d) => { out += d; });
      child.stderr.on('data', (d) => { err += d; });
      child.on('error', (e) => { this.#running.delete(job.job_id); resolve(emptyResult(this.id, 'unavailable', { summary: `claude: ${e.message}`, started_at: started })); });
      let timer = null;
      if (job.timeout_ms) timer = setTimeout(() => { try { child.kill('SIGTERM'); } catch {} }, job.timeout_ms);
      child.on('close', (code, signal) => {
        if (timer) clearTimeout(timer);
        const wasCancelled = this.#running.get(job.job_id)?.cancelled === true;
        this.#running.delete(job.job_id);
        resolve(this.#translate({ code, signal, out, err, started, cancelled: wasCancelled }));
      });
    });
  }

  async cancel(jobId) {
    const child = this.#running.get(jobId);
    if (!child) return;
    child.cancelled = true;
    try { child.kill('SIGTERM'); } catch {}
  }

  async usage() { return null; }

  // Vendor JSON → normalized result. Everything Claude-shaped stays in here.
  #translate({ code, signal, out, err, started, cancelled }) {
    const ended = new Date().toISOString();
    let raw = null;
    try { raw = out.trim() ? JSON.parse(out.trim().split('\n').pop()) : null; } catch { raw = null; }
    const base = { started_at: started, ended_at: ended, raw, stderr: err.trim() || null };
    if (cancelled || signal === 'SIGTERM') return emptyResult(this.id, 'cancelled', { ...base, summary: 'cancelled' });
    const text = String(raw?.result ?? '');
    if (raw?.is_error && USAGE_LIMIT_RE.test(text)) {
      return emptyResult(this.id, 'rate_limited', { ...base, summary: text, reset_at: raw.reset_at_epoch ?? null });
    }
    if (raw == null || code !== 0) {
      return emptyResult(this.id, code === 0 ? 'failed' : 'unavailable', { ...base, summary: (err.trim() || text || `claude exited ${code}`).slice(0, 2000) });
    }
    if (raw.is_error) return emptyResult(this.id, 'failed', { ...base, summary: text });
    return emptyResult(this.id, 'completed', { ...base, summary: text, model: raw.model ?? null });
  }
}

export const claude = registerExecutor(new ClaudeCodeExecutor());
export default claude;
