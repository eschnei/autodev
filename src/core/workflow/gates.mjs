// autoDev — the two human gates as deterministic core logic (Milestone 8, first
// extracted transition). A gate passes only by an explicit human decision; the
// engine records it with an audit comment on the issue, an event in the sidecar
// history, and — for Gate 1 — the stage move. What happens NEXT (breakdown, the
// squash-merge) is a bounded job for the model; whether it happened is verified by
// core afterwards, never trusted from the model's say-so.
//
// Gate 1: PRD Review (H) ──approve──▶ Breakdown            (then job: breakdown)
// Gate 2: Human Review (H) ──approve──▶ (recorded)         (then job: merge story; verified → Done)
//         Human Review (H) ──reject───▶ AI Development     (with the reason)

import { GATES } from '../config/schema.mjs';
import { appendEvent } from '../events.mjs';

export class GateError extends Error {}

export function gateOf(issue) {
  if (!issue) return null;
  if (issue.stage === GATES.gate1) return 1;
  if (GATES.gate2.includes(issue.stage)) return 2;
  return null;
}

function stamp(by) { return `${by || 'operator'} via autodev CLI, ${new Date().toISOString().slice(0, 16).replace('T', ' ')} UTC`; }

// Records a human approval. Returns { gate, issue, next, moved } where next is the
// bounded job the caller should now run ('breakdown' | 'merge_story').
export function approve({ tracker, projectId, issueId, by, note, env }) {
  const issue = tracker.issue(issueId);
  if (!issue) throw new GateError(`${issueId}: not found on the board`);
  const gate = gateOf(issue);
  if (!gate) throw new GateError(`${issue.id} is in "${issue.stage}", not at a human gate (Gate 1 = prd_review, Gate 2 = ready_for_human_review / ready_for_human_acceptance)`);
  const audit = `✅ Gate ${gate} approved by ${stamp(by)}${note ? ` — ${note}` : ''}`;
  let next, moved = null;
  if (gate === 1) {
    tracker.move(issue.id, 'breakdown', audit);      // note lands as the audit comment
    moved = 'breakdown'; next = 'breakdown';
  } else {
    tracker.comment(issue.id, audit);
    next = issue.stage === 'ready_for_human_acceptance' ? 'ship_feature' : 'merge_story';
  }
  const event = appendEvent(projectId, { type: 'gate.approved', gate, issue: issue.id, by: by || 'operator', note: note || null, from: issue.stage, to: moved || issue.stage, next }, { env });
  return { gate, issue: issue.id, next, moved, event };
}

// Records a human rejection at Gate 2 (Gate 1 rejection = "tell me changes" — the
// PRD is revised in conversation, so it stays at PRD Review with the comment).
export function reject({ tracker, projectId, issueId, by, reason, env }) {
  if (!reason) throw new GateError('a rejection needs a reason — the dev agent fixes what you name');
  const issue = tracker.issue(issueId);
  if (!issue) throw new GateError(`${issueId}: not found on the board`);
  const gate = gateOf(issue);
  if (!gate) throw new GateError(`${issue.id} is in "${issue.stage}", not at a human gate`);
  const audit = `❌ Gate ${gate} rejected by ${stamp(by)} — ${reason}`;
  let moved = null;
  if (gate === 2) { tracker.move(issue.id, 'ai_development', audit); moved = 'ai_development'; }
  else tracker.comment(issue.id, audit);
  const event = appendEvent(projectId, { type: 'gate.rejected', gate, issue: issue.id, by: by || 'operator', reason, from: issue.stage, to: moved || issue.stage }, { env });
  return { gate, issue: issue.id, moved, event };
}

// The bounded job a gate decision hands to the model. Deliberately narrow: the
// decision is already recorded; the model must not re-ask, re-decide, or wander.
export function jobFor(next, issueId, cfg) {
  const base = 'The human gate decision is ALREADY recorded on the board by autoDev (audit comment + stage). Do not ask for approval again and do not move the issue across any gate. Do exactly this bounded unit of work, log each action on the board per the manual, then stop.';
  switch (next) {
    case 'breakdown':
      return { role: 'project_manager', task: `${base}\n\nTask: run the breakdown for ${issueId} per reference/breakdown.md (the PRD was approved at Gate 1). Create the stories with the instance label, dependencies, risk class, persona routing, and AI-QA/manual test steps; leave the stories in Ready for AI Dev.` };
    case 'merge_story':
      return { role: 'implementation', task: `${base}\n\nTask: ${issueId} passed Gate 2. Squash-merge its story branch into the feature branch per reference/devloop.md §7 (merge_policy.story_to_feature = ${cfg.merge_policy?.story_to_feature || 'squash'}), run reference/merge-verify.md §1 (clean-room integration check; auto-revert on fail and reopen the story), and only if it holds move ${issueId} to done with a note. Back up the feature branch if backup.enabled and delivery is draft_pr. Never touch ${cfg.repo?.default_branch || 'main'}.` };
    case 'ship_feature':
      return { role: 'verification', task: `${base}\n\nTask: the feature ${issueId} was accepted at Gate 2 (feature acceptance). Deliver it per the Delivery mode in reference/manual.md (draft_pr → open the feature PR and attach its URL; local_diff → present the local diff). The human merges; never push ${cfg.repo?.default_branch || 'main'}.` };
    default:
      throw new GateError(`no job for "${next}"`);
  }
}
