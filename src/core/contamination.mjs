// autoDev — the contamination guard (M12A).
//
// The application repository must never carry autoDev, Brain, or Marj artifacts
// that the sidecar owns. This scans a repo root for them; it never deletes —
// Git records reality, humans decide. Called after every job (result annotated,
// event recorded), inside run_verification (a contaminated repo cannot PASS),
// and in get_status.
//
// v2 deployments legitimately carry `.autodev/` (config + board) and `.claude/`;
// a sidecar (v3-native or migrated) project must not gain a NEW `.autodev/`.

import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { git } from './git.mjs';

// [name, applies-in-sidecar-only?]
const FORBIDDEN = Object.freeze([
  ['.brain', false], ['brain.db', false], ['.marj', false], ['MARJ.md', false], ['marj.md', false],
  ['.autodev', true],
]);
const FORBIDDEN_PATTERNS = [/^brain-.*\.db$/i, /^\.marj[.-]/i, /^autodev-state/i];

export function scanContamination(root, { sidecar = false } = {}) {
  if (!root || !existsSync(root)) return [];
  const found = [];
  let entries = []; try { entries = readdirSync(root); } catch { return []; }
  for (const [name, sidecarOnly] of FORBIDDEN) {
    if (sidecarOnly && !sidecar) continue;
    if (entries.includes(name)) found.push({ path: name, reason: sidecarOnly ? 'sidecar project gained a repo-local autoDev dir' : 'sidecar-owned artifact inside the repo' });
  }
  for (const e of entries) if (FORBIDDEN_PATTERNS.some((re) => re.test(e))) found.push({ path: e, reason: 'looks like Brain/Marj state' });
  // executor-projected personas belong to the user's Claude home, never the repo
  const agents = join(root, '.claude', 'agents');
  if (existsSync(agents)) { try { const a = readdirSync(agents).filter((f) => f.startsWith('autodev-')); if (a.length) found.push({ path: '.claude/agents', reason: `${a.length} autodev-projected persona file(s) inside the repo` }); } catch {} }
  return found;
}

// Untracked/modified paths that appeared between two `git status --porcelain`
// snapshots and match the forbidden set — the per-job delta.
export function contaminationDelta(root, before, { sidecar = false } = {}) {
  const now = scanContamination(root, { sidecar });
  const seen = new Set((before || []).map((x) => x.path));
  return now.filter((x) => !seen.has(x.path));
}

export function describeContamination(list) {
  return list.length ? list.map((x) => `${x.path} (${x.reason})`).join(' · ') : 'clean';
}

// Is any forbidden path tracked by git? (a past mistake already committed)
export function trackedContamination(root, { sidecar = false } = {}) {
  const out = git(root, ['ls-files']) || '';
  const top = new Set(out.split('\n').filter(Boolean).map((p) => p.split('/')[0]));
  return FORBIDDEN.filter(([n, so]) => (!so || sidecar) && top.has(n)).map(([n]) => n);
}

export { FORBIDDEN };
export function isSidecarProject(ctx) { return !!(ctx?.legacy?.sidecar || ctx?.project?.tracker?.mode === 'sidecar' || ctx?.project?.migrated); }
export function fileAge(root, rel) { try { return Date.now() - statSync(join(root, rel)).mtimeMs; } catch { return null; } }
