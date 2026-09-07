// autoDev ↔ Brain integration (Milestone 13).
//
//   autoDev identifies project/task → Brain.context() → autoDev builds the Job
//   (Brain context in front of the task, bundle id + memory revisions recorded)
//   → executor runs → autoDev verifies → Brain.handoff() / decisions.
//
// Brain is OPTIONAL. brain.enabled=false means v2 behavior. When enabled but
// unreachable or incompatible, autoDev runs in DEGRADED mode: it says so, keeps
// working from git + local state, and never treats a stale cache as canonical
// (there is no cache yet — M19). Nothing here throws into a tick.

import { BrainClient, BrainIncompatible, BrainUnreachable, resolveToken } from './client.mjs';
import { saveProject } from '../core/project.mjs';
import { appendEvent } from '../core/events.mjs';

// One status object the CLI banner, doctor, and tick all agree on.
export async function brainStatus(cfg, project, { env = process.env, fetchImpl } = {}) {
  if (!cfg?.brain?.enabled) return { state: 'off', reason: 'brain.enabled=false' };
  if (!cfg.brain.url) return { state: 'off', reason: 'brain.url not set' };
  const { token, source, scoped } = resolveToken(env, { projectId: project?.id });
  if (!token) return { state: 'degraded', url: cfg.brain.url, reason: 'no token ($BRAIN_TOKEN, ~/.config/autodev/brain.token, or Keychain "brain")' };
  const client = new BrainClient({ url: cfg.brain.url, token, fetchImpl });
  try {
    const info = await client.connect();
    return { state: 'connected', url: cfg.brain.url, api: info.api, capabilities: info.capabilities, project_id: project?.brain?.project_id || cfg.brain.project_id || null, token_source: source, token_scoped: !!scoped, client };
  } catch (e) {
    if (e instanceof BrainIncompatible) return { state: 'incompatible', url: cfg.brain.url, reason: e.message };
    if (e instanceof BrainUnreachable) return { state: 'degraded', url: cfg.brain.url, reason: e.message };
    return { state: 'degraded', url: cfg.brain.url, reason: `${e.code || 'error'}: ${e.message}` };
  }
}

export function describeBrain(s) {
  switch (s.state) {
    case 'connected': return `connected (${s.url} · api ${s.api}${s.project_id ? ` · ${s.project_id}` : ' · project not registered'})`;
    case 'degraded': return `DEGRADED — ${s.reason} (working from git + local state; Brain writes are skipped)`;
    case 'incompatible': return `INCOMPATIBLE — ${s.reason}`;
    default: return 'not configured';
  }
}

// Idempotent registration of the sidecar project in Brain: by stored id, else by
// key (the sidecar project name slug), else create. Stores brain.project_id in the
// sidecar project.json — never in the application repo.
export async function ensureBrainProject(status, ctx, { log = () => {} } = {}) {
  if (status.state !== 'connected') return null;
  const { client } = status;
  const project = ctx.project;
  const key = project.key || slug(project.name);
  let bp = null;
  if (project.brain?.project_id) { try { bp = await client.project(project.brain.project_id); } catch (e) { if (e.status !== 404) throw e; } }
  if (!bp) { try { bp = await client.project(key); } catch (e) { if (e.status !== 404) throw e; } }
  if (!bp) {
    bp = await client.createProject({ name: project.name, key, external_refs: { autodev_project_id: project.id, ...(ctx.legacy?.client_name ? { legacy_autodev: ctx.legacy.client_name } : {}) } }, { idempotencyKey: `autodev:${project.id}:project` });
    log(`brain: registered project ${bp.id} (${key})`);
  }
  if (ctx.identity) {
    await client.registerRepository(bp.id, { name: ctx.identity.name, remote: ctx.identity.remote, root_commit: ctx.identity.root_commit });
  }
  if (project.brain?.project_id !== bp.id) {
    project.brain = { ...(project.brain || {}), enabled: true, project_id: bp.id, url: status.url };
    saveProject(project);
  }
  status.project_id = bp.id;
  return bp;
}

const slug = (s) => String(s || 'project').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');

// Context for a job. Returns { bundle, text } or null (degraded / not registered).
export async function contextForJob(status, ctx, { requirement_key, task_key, role, executor, branch, budget = 40, log = () => {} } = {}) {
  if (status.state !== 'connected' || !status.project_id) return null;
  try {
    const bundle = await status.client.context({ project_id: status.project_id, requirement_id: await resolveRequirement(status, requirement_key), branch, role, executor, budget });
    appendEvent(ctx.project.id, { type: 'brain.context.supplied', project_id: status.project_id, context_bundle_id: bundle.id, api: status.api, executor, role, memories: bundle.memories.map((m) => ({ id: m.id, revision: m.revision })), handoff: bundle.handoff?.id || null });
    return { bundle, text: renderContext(bundle) };
  } catch (e) { log(`brain: context unavailable (${e.message}) — continuing without it`); return null; }
}

async function resolveRequirement(status, key) {
  if (!key) return undefined;
  try { const reqs = await status.client.requirements(status.project_id); return reqs.find((r) => r.key === key || r.external_refs?.legacy_autodev === key)?.id; } catch { return undefined; }
}

// The block an executor sees in front of its task. Rules and decisions first,
// failures next, then the rest; the latest handoff last. Compact by design.
export function renderContext(b) {
  const line = (m) => `- [${m.scope.type}${m.via ? ` via ${m.via.name}` : ''} · ${m.state}] ${m.content.replace(/\s+/g, ' ').trim()}`;
  const group = (t, title) => { const xs = b.memories.filter((m) => t.includes(m.type)); return xs.length ? [`### ${title}`, ...xs.map(line)] : []; };
  const rest = b.memories.filter((m) => !['rule', 'convention', 'decision', 'failure', 'contract'].includes(m.type));
  const out = [`## Brain context (${b.id} — project ${b.project.name}; ${b.memories.length} memories${b.omitted ? `, ${b.omitted} omitted` : ''})`,
    'What the project already knows. Treat rules and decisions as binding; observations as leads, not facts. Do not re-derive what is settled here.'];
  out.push(...group(['rule', 'convention'], 'Rules'), ...group(['decision'], 'Decisions'), ...group(['contract'], 'Contracts of related projects'), ...group(['failure'], 'Known failures'));
  if (rest.length) out.push('### Other', ...rest.map(line));
  if (b.requirement) out.push(`### Requirement ${b.requirement.key || b.requirement.id}: ${b.requirement.title}`, ...(b.requirement.acceptance_criteria || []).map((c) => `- ${c}`));
  if (b.handoff) out.push(`### Latest handoff (${b.handoff.executor || 'unknown executor'}, ${b.handoff.created_at})`, b.handoff.summary, ...(b.handoff.payload?.tests_failed?.length ? [`Failing tests: ${b.handoff.payload.tests_failed.join(', ')}`] : []), ...(b.handoff.payload?.recommended_next_steps?.length ? ['Next steps it recommended:', ...b.handoff.payload.recommended_next_steps.map((s) => `- ${s}`)] : []));
  return out.join('\n');
}

// After a job: the handoff is what the NEXT executor (any vendor) starts from.
export async function recordHandoff(status, ctx, job, result, { requirement_key, log = () => {} } = {}) {
  if (status.state !== 'connected' || !status.project_id) return null;
  try {
    const summary = result.summary?.trim() || `${result.executor} ${result.status}`;
    const payload = { job_id: job.job_id, role: job.role, status: result.status, files_changed: result.files_changed, tests_run: result.tests_run, tests_passed: result.tests_passed, tests_failed: result.tests_failed, decisions: result.decisions, discoveries: result.discoveries, blockers: result.blockers, recommended_next_steps: result.recommended_next_steps, context_bundle_id: job.context?.brain?.bundle_id || null, branch: job.context?.branch || null, started_at: result.started_at, ended_at: result.ended_at };
    const h = await status.client.handoff({ project_id: status.project_id, requirement_id: await resolveRequirement(status, requirement_key), executor: result.executor, summary: summary.slice(0, 4000), payload }, { idempotencyKey: job.job_id });
    appendEvent(ctx.project.id, { type: 'brain.handoff.recorded', handoff_id: h.id, job_id: job.job_id, executor: result.executor, replayed: !!h.replayed });
    return h;
  } catch (e) { log(`brain: handoff not recorded (${e.message})`); return null; }
}

// Human gate decisions are the highest-authority provenance Brain has.
export async function recordGateDecision(status, ctx, decision, { log = () => {} } = {}) {
  if (status.state !== 'connected' || !status.project_id) return null;
  try {
    return await status.client.decision({ project_id: status.project_id, title: `Gate ${decision.gate} ${decision.event.type === 'gate.rejected' ? 'rejected' : 'approved'}: ${decision.issue}`, decision: decision.event.type === 'gate.rejected' ? `rejected — ${decision.event.reason}` : `approved${decision.event.note ? ` — ${decision.event.note}` : ''}`, rationale: `recorded by autoDev; board event ${decision.event.id}`, by: decision.event.by }, { idempotencyKey: decision.event.id });
  } catch (e) { log(`brain: gate decision not recorded (${e.message})`); return null; }
}

export { BrainClient, BrainIncompatible, BrainUnreachable, resolveToken };
