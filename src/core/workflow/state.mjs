// autoDev — deterministic workflow state (Milestone 8: autoDev owns the state
// machine; the model owns analysis/planning/implementation/review).
//
//   autoDev reads deterministic state   ← this file
//         ↓
//   autoDev determines next action      ← nextAction()
//         ↓
//   autoDev gives a bounded job to the model
//         ↓
//   autoDev verifies the result
//
// Everything here is computable from the board + config with no LLM and no
// subprocess: tests/suite/workflow.sh pins it. The rules are the ones
// commands/loop.md and reference/devloop.md §1–2 state in prose; those manuals
// remain compatibility documentation for the plugin path.

import { GATES, STAGES } from '../config/schema.mjs';

const labelOf = (cfg, key, dflt) => cfg.tracker?.labels?.[key] || dflt;

export function isFeature(issue, cfg) {
  return (issue.labels || []).includes(labelOf(cfg, 'route_feature', 'route:feature'));
}

// A story's blockers: relations of type `blocks` on OTHER issues pointing at it,
// or `blocked_by` relations on the story itself (both spellings exist on boards).
export function blockersOf(issue, all) {
  const ids = new Set();
  for (const r of issue.relations || []) if (r.type === 'blocked_by' || r.type === 'blocked by') ids.add(r.id);
  for (const other of all) for (const r of other.relations || []) if (r.type === 'blocks' && r.id === issue.id) ids.add(other.id);
  return [...ids].map((id) => all.find((i) => i.id === id)).filter(Boolean);
}

// reference/devloop.md §2: oldest Ready-for-AI-Dev story carrying ai-eligible (+ the
// instance label — `own` is already lane-filtered), whose every blocker is done.
// File-overlap with in-flight work needs the story body's "Touched files"; when a
// story declares none, it is not excluded (the prose engine makes the same call).
export function eligibleStories(own, cfg) {
  const aiEligible = labelOf(cfg, 'ai_eligible', 'ai-eligible');
  const inFlightFiles = new Set(own.filter((i) => ['ai_development', 'ai_qa'].includes(i.stage)).flatMap((i) => touchedFiles(i)));
  return own
    .filter((i) => i.stage === 'ready_for_ai_dev' && (i.labels || []).includes(aiEligible) && !isFeature(i, cfg))
    .filter((i) => blockersOf(i, own).every((b) => b.stage === 'done'))
    .filter((i) => !touchedFiles(i).some((f) => inFlightFiles.has(f)))
    .sort((a, b) => Number(a.id.split('-')[1]) - Number(b.id.split('-')[1]));
}

// "Touched files" section of a story body, one path per line (story-template.md).
export function touchedFiles(issue) {
  const m = /touched files:?\s*\n([\s\S]*?)(?:\n\s*\n|\n#|$)/i.exec(issue.description || '');
  if (!m) return [];
  return m[1].split('\n').map((l) => l.replace(/^[\s*-]+/, '').trim()).filter((l) => l && !l.startsWith('#'));
}

export function readWorkflowState(tracker, cfg) {
  const all = tracker.readIssues();
  const own = tracker.ownIssues();
  const at = (stage) => own.filter((i) => i.stage === stage);
  const state = {
    counts: Object.fromEntries(Object.keys(STAGES).map((k) => [k, at(k).length])),
    gates: {
      gate1: at(GATES.gate1),                                       // PRD Review (H)
      gate2: GATES.gate2.flatMap((s) => at(s)),                     // Human Review (H) / acceptance
    },
    blocked: at('blocked'),
    clarifying: at('clarifying'),
    breakdown: at('breakdown'),
    in_flight: [...at('ai_development'), ...at('ai_qa')],
    eligible: eligibleStories(own, cfg),
    features_in_development: own.filter((i) => isFeature(i, cfg) && !['done', 'new_request', 'clarifying', 'prd_review', 'breakdown'].includes(i.stage)),
    foreign: all.length - own.length,
    total: all.length,
  };
  state.awaiting_human = [...state.gates.gate1, ...state.gates.gate2, ...state.blocked, ...state.clarifying];
  return state;
}

// commands/loop.md's decision order, made explicit. Gate approvals are NOT
// inferred from conversation any more — they are recorded by gates.approve();
// an approved PRD is simply an issue sitting in `breakdown`.
export function nextAction(state, cfg) {
  const lanes = cfg.execution?.max_lanes ?? 5;
  if (state.breakdown.length) return { action: 'breakdown', issues: state.breakdown.map((i) => i.id), reason: 'a PRD was approved (Gate 1) and awaits decomposition' };
  if (state.eligible.length) {
    const free = Math.max(0, lanes - state.in_flight.length);
    if (free > 0) return { action: 'develop', issues: state.eligible.slice(0, free).map((i) => i.id), reason: `${state.eligible.length} eligible · ${state.in_flight.length} in flight · ${free} free lane(s)` };
    return { action: 'wait', reason: `all ${lanes} lanes busy` };
  }
  if (state.in_flight.length) return { action: 'wait', issues: state.in_flight.map((i) => i.id), reason: 'work in flight; the heartbeat continues it' };
  if (state.awaiting_human.length) return { action: 'await_human', issues: state.awaiting_human.map((i) => i.id), reason: `${state.gates.gate1.length} at Gate 1 · ${state.gates.gate2.length} at Gate 2 · ${state.blocked.length} blocked · ${state.clarifying.length} clarifying` };
  return { action: 'idle', reason: cfg.backlog?.enabled ? 'nothing queued — backlog drain may ask for a batch' : 'nothing queued' };
}

export function describeState(state, cfg) {
  const name = (k) => cfg.tracker?.statuses?.[k]?.name || STAGES[k]?.name || k;
  const list = (arr) => arr.map((i) => `${i.id} ${i.title}`).join(' · ') || '—';
  return [
    `Gate 1 (${name('prd_review')}): ${list(state.gates.gate1)}`,
    `Gate 2 (${name('ready_for_human_review')}): ${list(state.gates.gate2)}`,
    `Blocked: ${list(state.blocked)}`,
    `Awaiting breakdown: ${list(state.breakdown)}`,
    `In flight: ${list(state.in_flight)}`,
    `Eligible next: ${list(state.eligible)}`,
    ...(state.foreign ? [`(${state.foreign} issue(s) not in this instance's lane — untouched)`] : []),
  ].join('\n');
}
