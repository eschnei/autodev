// autoDev — the headless permission allowlist, built from THIS repo's config.
// Ported verbatim from the bash in scripts/devloop-tick.sh (AD-17 hardening) so the
// runner suite's invariants keep holding: never `gh pr merge` (only humans merge),
// never bare `node` (node -e = arbitrary exec), never bare `jq`, never a
// default-branch push. `node` is scoped to the engine's own tracker helper, in
// both spellings the agent docs use. Executor-agnostic: this is a list of
// permission strings; each executor adapter maps it to its own mechanism.

export function headlessAllowlist(cfg) {
  const allow = [];
  const add = (s) => allow.push(s);
  for (const c of ['install', 'test', 'lint', 'build', 'app_run']) {
    const v = cfg.commands?.[c];
    if (v) add(`Bash(${v})`);
  }
  const featurePrefix = cfg.repo?.feature_branch_prefix || 'feature/';
  const storyPrefix = cfg.repo?.story_branch_prefix || 'autodev';
  const backupRemote = cfg.backup?.remote || 'origin';
  for (const g of ['status', 'add', 'commit', 'checkout', 'switch', 'branch', 'worktree', 'diff', 'log', 'rebase', 'merge --squash']) add(`Bash(git ${g}:*)`);
  add(`Bash(git push origin ${featurePrefix}*)`);
  add(`Bash(git push origin ${storyPrefix}/*)`);
  add(`Bash(git push ${backupRemote} ${featurePrefix}*)`);
  for (const g of ['create', 'view', 'comment', 'checks']) add(`Bash(gh pr ${g}:*)`);
  // NO gh pr merge grant — see scripts/devloop-tick.sh history + manual.md non-negotiable 3
  add('Bash(node ${CLAUDE_PLUGIN_ROOT}/scripts/tracker.mjs *)');
  add('Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/tracker.mjs" *)');
  add('mcp__linear__*');
  add('mcp__playwright__*');
  return allow;
}

// Invariants any allowlist must satisfy before it reaches an executor. Throws on
// violation: a misbuilt list is a bug, not a degraded mode.
export function assertAllowlistInvariants(allow, cfg) {
  const defaultBranch = cfg.repo?.default_branch || 'main';
  const bad = allow.find((a) =>
    /gh pr merge/.test(a) ||
    /^Bash\(node \*\)$/.test(a) || /^Bash\(node\)/.test(a) ||
    /^Bash\(jq/.test(a) ||
    new RegExp(`git push [^ ]+ \\+?${defaultBranch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(\\b|:|$)`).test(a));
  if (bad) throw new Error(`allowlist invariant violated: ${bad}`);
  return allow;
}
