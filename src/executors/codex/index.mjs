// autoDev — CodexExecutor (Milestone 15). THE ONLY place the `codex` CLI is invoked.
//
// Subscription-native: shells out to the user's authenticated Codex CLI
// (`codex login` → ChatGPT/Codex subscription); no credential passes through
// autoDev. Same Job in, same normalized ExecutionResult out as ClaudeCodeExecutor.
//
// Wire contract used (codex exec, non-interactive):
//   codex exec --json -c approval_policy=never -s <sandbox> -C <cwd> [-m model] -o <last-message-file> -
//   prompt on stdin; JSONL events on stdout:
//     thread.started · turn.started · item.started/updated/completed
//       item.type: agent_message{text} · command_execution{command,exit_code,aggregated_output}
//                  file_change{changes:[{path,kind}]} · reasoning · mcp_tool_call · error{message}
//     turn.completed{usage} · turn.failed{error} · error{message}
//   The parser is tolerant: any of those may be missing; -o's file is the fallback summary.
//
// Permissions: Codex has no per-command allowlist. A Job's allowed_tools become
//   (1) a sandbox choice (workspace-write; network on only when the allowlist grants
//       git push / gh) and (2) explicit prohibitions in the prompt. capabilities()
//   reports tool_allowlist:false so core knows the guard is prompt-level + post-verified,
//   not mechanical (M8A re-homes the mechanical guard executor-independently).

import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { emptyResult, registerExecutor } from '../executor.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const LIMIT_RE = /rate limit|usage limit|quota|too many requests|429/i;

// Codex cannot read the plugin's manuals the way Claude (with the plugin loaded)
// can, so `reference/<name>.md` mentions in a task are inlined, bounded.
export function inlineReferences(task, { root = ROOT, maxChars = 12000 } = {}) {
  const seen = new Set(); const blocks = [];
  for (const m of task.matchAll(/reference\/([a-z0-9-]+)\.md/g)) {
    const p = join(root, 'reference', `${m[1]}.md`);
    if (seen.has(p) || !existsSync(p)) continue;
    seen.add(p);
    const text = readFileSync(p, 'utf8');
    blocks.push(`===== reference/${m[1]}.md =====\n${text.length > maxChars ? text.slice(0, maxChars) + '\n[… truncated …]' : text}\n===== end =====`);
  }
  return blocks.length ? `${task}\n\nThe documents referenced above, for this run:\n\n${blocks.join('\n\n')}` : task;
}

export function prohibitions(job, cfg = {}) {
  const allow = job.permissions?.allowed_tools || [];
  const branch = cfg.repo?.default_branch || 'main';
  const rules = [`Never push, merge, or rebase onto the default branch "${branch}"; never run \`gh pr merge\`; only humans merge.`];
  if (!allow.some((a) => /git push/.test(a))) rules.push('Do not push at all in this run.');
  if (!allow.some((a) => /gh pr/.test(a))) rules.push('Do not use `gh`.');
  rules.push('Never edit AGENTS.md or CLAUDE.md (team-owned).', 'Do not read or write anything outside this repository except via the tools you were given.');
  return `Hard rules for this run (autoDev enforces them and verifies afterwards):\n${rules.map((r) => `- ${r}`).join('\n')}`;
}

export class CodexExecutor {
  id = 'codex';
  #bin; #running = new Map(); #cfg;
  constructor({ bin = 'codex', cfg = {} } = {}) { this.#bin = bin; this.#cfg = cfg; }

  async available() {
    const r = process.platform === 'win32' ? spawnSync('where', [this.#bin], { encoding: 'utf8' }) : spawnSync('/bin/sh', ['-c', 'command -v -- "$0"', this.#bin], { encoding: 'utf8' });
    return r.status === 0;
  }
  async capabilities() {
    return { id: this.id, auth: 'subscription', streaming: true, tool_allowlist: false, sandbox: true, cancel: true, usage: false, executes_commands: 'sandboxed', guards: 'prompt+post-verify' };
  }
  async probe() {
    const r = await this.execute({ job_id: `probe_${Date.now()}`, task: 'reply with exactly: ok', permissions: { allowed_tools: [] }, cwd: process.cwd(), role: 'probe' });
    return r.status === 'completed';
  }
  async usage() { return null; }

  execute(job) {
    const allow = job.permissions?.allowed_tools || [];
    const network = allow.some((a) => /git push|gh pr|mcp__/.test(a));
    const tmp = mkdtempSync(join(tmpdir(), 'autodev-codex-'));
    const last = join(tmp, 'last-message.txt');
    const args = ['exec', '--json', '-c', 'approval_policy=never', '-s', 'workspace-write', '-C', job.cwd || process.cwd(), '-o', last, '--skip-git-repo-check'];
    if (network) args.push('-c', 'sandbox_workspace_write.network_access=true');
    if (job.context?.model) args.push('-m', job.context.model);
    args.push('-');
    const prompt = job.role === 'probe' ? job.task : `${prohibitions(job, this.#cfg)}\n\n${inlineReferences(job.task)}`;
    const started = new Date().toISOString();
    return new Promise((resolve) => {
      let out = '', err = '', child;
      try { child = spawn(this.#bin, args, { cwd: job.cwd || process.cwd(), env: process.env, stdio: ['pipe', 'pipe', 'pipe'] }); }
      catch (e) { rmSync(tmp, { recursive: true, force: true }); return resolve(emptyResult(this.id, 'unavailable', { summary: String(e.message), started_at: started })); }
      this.#running.set(job.job_id, child);
      child.stdout.on('data', (d) => { out += d; });
      child.stderr.on('data', (d) => { err += d; });
      child.on('error', (e) => { this.#running.delete(job.job_id); rmSync(tmp, { recursive: true, force: true }); resolve(emptyResult(this.id, 'unavailable', { summary: `codex: ${e.message}`, started_at: started })); });
      let timer = null;
      if (job.timeout_ms) timer = setTimeout(() => { try { child.kill('SIGTERM'); } catch {} }, job.timeout_ms);
      child.on('close', (code, signal) => {
        if (timer) clearTimeout(timer);
        const cancelled = this.#running.get(job.job_id)?.cancelled === true;
        this.#running.delete(job.job_id);
        let lastMsg = null; try { lastMsg = readFileSync(last, 'utf8').trim() || null; } catch {}
        rmSync(tmp, { recursive: true, force: true });
        resolve(this.#translate({ code, signal, out, err, started, cancelled, lastMsg }));
      });
      child.stdin.on('error', () => {});
      child.stdin.end(prompt);
    });
  }
  async cancel(jobId) { const c = this.#running.get(jobId); if (!c) return; c.cancelled = true; try { c.kill('SIGTERM'); } catch {} }

  #translate({ code, signal, out, err, started, cancelled, lastMsg }) {
    const ended = new Date().toISOString();
    const events = out.split('\n').filter((l) => l.trim().startsWith('{')).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    const items = events.filter((e) => e.type === 'item.completed' && e.item).map((e) => e.item);
    const messages = items.filter((i) => i.type === 'agent_message').map((i) => i.text).filter(Boolean);
    const files = [...new Set(items.filter((i) => i.type === 'file_change').flatMap((i) => (i.changes || []).map((c) => c.path)).filter(Boolean))];
    const cmds = items.filter((i) => i.type === 'command_execution');
    const failedCmds = cmds.filter((c) => c.exit_code != null && c.exit_code !== 0).map((c) => c.command).filter(Boolean);
    const errors = [...events.filter((e) => e.type === 'error' || e.type === 'turn.failed').map((e) => e.error?.message || e.message), ...items.filter((i) => i.type === 'error').map((i) => i.message)].filter(Boolean);
    const usage = events.find((e) => e.type === 'turn.completed')?.usage || null;
    const base = { started_at: started, ended_at: ended, raw: { events: events.length, usage, last_message: lastMsg, errors }, stderr: err.trim() || null, files_changed: files, tests_failed: failedCmds.filter((c) => /test|spec|vitest|jest|pytest|mix test/.test(c)) };
    const summary = (messages.at(-1) || lastMsg || '').trim();
    if (cancelled || signal === 'SIGTERM') return emptyResult(this.id, 'cancelled', { ...base, summary: 'cancelled' });
    const errText = [...errors, err].join(' ');
    if (LIMIT_RE.test(errText) && (code !== 0 || errors.length)) return emptyResult(this.id, 'rate_limited', { ...base, summary: errors[0] || 'rate limited', reset_at: null });
    if (code !== 0 && !events.length) return emptyResult(this.id, 'unavailable', { ...base, summary: (err.trim() || `codex exited ${code}`).slice(0, 2000) });
    if (errors.length || (code !== 0 && !summary)) return emptyResult(this.id, 'failed', { ...base, summary: (errors[0] || summary || `codex exited ${code}`).slice(0, 2000) });
    return emptyResult(this.id, 'completed', { ...base, summary, model: usage?.model ?? null });
  }
}

export const codex = registerExecutor(new CodexExecutor());
export default codex;
