// autoDev — the Executor contract (PRD §6–8) and the executor registry.
//
// An executor is an interchangeable AI runtime (Claude Code, Codex, …). autoDev
// core never invokes a vendor CLI: every `claude …` call lives in
// executors/claude/, every `codex …` call will live in executors/codex/. Core
// hands an executor a Job and gets back a normalized ExecutionResult.
//
// Contract (duck-typed; there is no TypeScript in this repo by decision D1):
//
//   id: string                                   'claude' | 'codex' | …
//   available(): Promise<boolean>                the local client is installed + usable
//   capabilities(): Promise<ExecutorCapabilities>
//   execute(job: Job): Promise<ExecutionResult>
//   cancel(jobId: string): Promise<void>
//   usage(): Promise<UsageInfo|null>             subscription/quota info where observable
//
// Job (the only thing core sends; vendor-specific translation is the adapter's):
//   { job_id, project_id, requirement_id?, task_id?, role, task, cwd, context,
//     acceptance_criteria[], permissions: { allowed_tools[] }, verification,
//     expected_outputs, timeout_ms? }
//
// ExecutionResult (normalized; vendor formats never leak past the adapter):
//   { status: 'completed' | 'failed' | 'rate_limited' | 'unavailable' | 'cancelled',
//     summary, files_changed[], tests_run[], tests_passed[], tests_failed[],
//     decisions[], discoveries[], blockers[], recommended_next_steps[],
//     executor, model?, started_at, ended_at, reset_at?, raw }
//
// `raw` keeps the adapter's parsed vendor payload for logging/debugging only —
// core logic must never branch on it.

import { newId } from '../core/ids.mjs';

export function makeJob(fields) {
  if (!fields || typeof fields.task !== 'string' || !fields.task.trim()) throw new TypeError('makeJob: task is required');
  return {
    job_id: fields.job_id || newId('job'),
    project_id: fields.project_id || null,
    requirement_id: fields.requirement_id || null,
    task_id: fields.task_id || null,
    role: fields.role || 'implementation',
    task: fields.task,
    cwd: fields.cwd || process.cwd(),
    context: fields.context || {},
    acceptance_criteria: fields.acceptance_criteria || [],
    permissions: { allowed_tools: [], ...(fields.permissions || {}) },
    verification: fields.verification || {},
    expected_outputs: fields.expected_outputs || {},
    timeout_ms: fields.timeout_ms ?? null,
  };
}

export function emptyResult(executor, status, extra = {}) {
  const now = new Date().toISOString();
  return {
    status, summary: '', files_changed: [], tests_run: [], tests_passed: [], tests_failed: [],
    decisions: [], discoveries: [], blockers: [], recommended_next_steps: [],
    executor, model: null, started_at: now, ended_at: now, reset_at: null, raw: null,
    ...extra,
  };
}

// ---- registry ---------------------------------------------------------------------
const registry = new Map();

export function registerExecutor(executor) {
  for (const m of ['available', 'capabilities', 'execute', 'cancel', 'usage']) {
    if (typeof executor?.[m] !== 'function') throw new TypeError(`registerExecutor: "${executor?.id}" lacks ${m}()`);
  }
  registry.set(executor.id, executor);
  return executor;
}
export function getExecutor(id) {
  const e = registry.get(id);
  if (!e) throw new Error(`no executor "${id}" registered (available: ${[...registry.keys()].join(', ') || 'none'})`);
  return e;
}
export function listExecutors() { return [...registry.keys()]; }
export function hasExecutor(id) { return registry.has(id); }
