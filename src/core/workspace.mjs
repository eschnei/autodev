// autoDev — isolated executor workspaces (M8A).
//
// A story job runs in its OWN git worktree on its story branch
// (`<repo.story_branch_prefix>/sc-<id>/<slug>`, devloop §4), rooted under the
// sidecar's runtime dir for the project — never inside the application repo,
// never on the developer's checkout. Two lanes cannot trample each other, a
// crashed job leaves the main checkout untouched, and the worktree is reusable
// across heartbeats until the story is merged.
//
// Features, breakdown, review-only and verification jobs run against the main
// checkout (they need the feature branch / whole board view); only stories in
// ai_development / ai_qa get a lane.

import { existsSync, mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { git, branchExists, worktreeList, worktreeAdd, worktreeRemove, currentBranch } from './git.mjs';
import { projectRuntimeDir } from './paths.mjs';

export const LANE_STAGES = Object.freeze(['ready_for_ai_dev', 'ai_development', 'ai_qa']);

export function slugOf(title) { return String(title || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'story'; }
export function storyBranch(cfg, issue) { return `${cfg.repo?.story_branch_prefix || 'autodev'}/sc-${issue.id}/${slugOf(issue.title)}`; }
export function laneDir(projectId, issue, env) { return join(projectRuntimeDir(projectId, env), 'worktrees', issue.id); }

// The base a story branches from: the feature branch when the story's parent
// feature has one checked out, else the current branch of the main checkout,
// else the default branch. Never invents a branch.
function baseFor(root, cfg, issue, all) {
  const parent = (issue.relations || []).find((r) => r.type === 'child_of' || r.type === 'parent')?.id;
  const feature = parent && all ? all.find((i) => i.id === parent) : null;
  if (feature) { const fb = `${cfg.repo?.feature_branch_prefix || 'feature/'}${slugOf(feature.title)}`; if (branchExists(root, fb)) return fb; }
  return currentBranch(root) || cfg.repo?.default_branch || 'main';
}

export function wantsLane(issue, cfg, { isFeature = false } = {}) {
  return !!issue && !isFeature && LANE_STAGES.includes(issue.stage);
}

// Ensure the lane exists and return { cwd, branch, created, base }.
export function ensureLane({ root, projectId, cfg, issue, all, env }) {
  const branch = storyBranch(cfg, issue);
  const dir = laneDir(projectId, issue, env);
  const existing = worktreeList(root).find((w) => w.path === dir);
  if (existing) return { cwd: dir, branch: existing.branch || branch, created: false, base: null };
  // an existing story branch (from an earlier tick or a v2 run) is reused, never reset
  const base = baseFor(root, cfg, issue, all);
  mkdirSync(join(dir, '..'), { recursive: true });
  if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });   // stale dir without a worktree record
  worktreeAdd(root, dir, branch, { from: base });
  return { cwd: dir, branch, created: true, base };
}

export function removeLane({ root, projectId, issue, env, force = false }) {
  const dir = laneDir(projectId, issue, env);
  const w = worktreeList(root).find((x) => x.path === dir);
  if (w) worktreeRemove(root, dir, { force });
  else if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });
  git(root, ['worktree', 'prune']);
  return { removed: !!w || true, dir };
}

export function listLanes({ root, projectId, env }) {
  const base = join(projectRuntimeDir(projectId, env), 'worktrees');
  return worktreeList(root).filter((w) => w.path && w.path.startsWith(base)).map((w) => ({ issue: w.path.slice(base.length + 1), path: w.path, branch: w.branch, head: w.head }));
}
