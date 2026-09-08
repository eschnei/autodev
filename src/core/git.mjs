// autoDev — core git interface (Milestone 4). Git records code reality; core asks
// it questions and drives the worktree strategy through here, never via ad-hoc
// shell strings scattered across modules. Read-only helpers return null on
// failure; mutating helpers throw GitError.

import { spawnSync } from 'node:child_process';

export class GitError extends Error {}

export function git(cwd, args, { check = false } = {}) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  if (r.status !== 0) {
    if (check) throw new GitError(`git ${args.join(' ')}: ${(r.stderr || r.stdout).trim()}`);
    return null;
  }
  return r.stdout.replace(/\n$/, '');
}

export const toplevel      = (cwd) => git(cwd, ['rev-parse', '--show-toplevel']);
export const currentBranch = (cwd) => { const b = git(cwd, ['rev-parse', '--abbrev-ref', 'HEAD']); return b === 'HEAD' ? null : b; };
export const headSha       = (cwd) => git(cwd, ['rev-parse', 'HEAD']);
export const isClean       = (cwd) => git(cwd, ['status', '--porcelain']) === '';
export const branchExists  = (cwd, name) => git(cwd, ['show-ref', '--verify', '--quiet', `refs/heads/${name}`]) !== null;
export const remoteUrl     = (cwd, remote = 'origin') => git(cwd, ['remote', 'get-url', remote]);

// Has `branch` been merged into `base`? (its tip is an ancestor of base)
export function mergedInto(cwd, branch, base) {
  const tip = git(cwd, ['rev-parse', branch]); if (!tip) return false;
  return git(cwd, ['merge-base', '--is-ancestor', tip, base]) !== null;
}

// Commits on `branch` not on `base`, oldest first: [{sha, subject}]
export function commitsAhead(cwd, branch, base) {
  const out = git(cwd, ['log', '--reverse', '--format=%H%x1f%s', `${base}..${branch}`]);
  if (!out) return [];
  return out.split('\n').filter(Boolean).map((l) => { const [sha, subject] = l.split('\x1f'); return { sha, subject }; });
}

// ---- worktrees (the story-isolation strategy the manual prescribes) ----
export function worktreeList(cwd) {
  const out = git(cwd, ['worktree', 'list', '--porcelain']);
  if (!out) return [];
  return out.split('\n\n').filter(Boolean).map((block) => {
    const w = {};
    for (const line of block.split('\n')) { const [k, ...v] = line.split(' '); w[k] = v.join(' ') || true; }
    return { path: w.worktree, head: w.HEAD, branch: w.branch ? String(w.branch).replace('refs/heads/', '') : null, bare: w.bare === true, detached: w.detached === true };
  });
}
export function worktreeAdd(cwd, path, branch, { from } = {}) {
  const args = ['worktree', 'add'];
  if (!branchExists(cwd, branch)) args.push('-b', branch, path, from || 'HEAD'); else args.push(path, branch);
  git(cwd, args, { check: true });
  return path;
}
export function worktreeRemove(cwd, path, { force = false } = {}) {
  git(cwd, ['worktree', 'remove', ...(force ? ['--force'] : []), path], { check: true });
}
