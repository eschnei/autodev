// autoDev — migration discovery + classification (PRD §40–42, §68; Milestone 14).
//
// Reads an existing Claude/autoDev project (and the developer's user-level Claude
// configuration) and classifies every artifact. It NEVER writes:
//
//   portable          becomes Brain or autoDev-native data directly
//   adaptable         intent is portable, executor implementation differs
//   vendor-specific   cannot be translated reliably; preserved, reported
//   legacy            kept only for compatibility
//
// Scope tells the translator who owns the artifact: project (this repo), user
// (developer-wide), executor (one vendor's runtime). User-level artifacts become
// reviewable candidates, never silent global memory.

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, basename } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { git } from '../core/git.mjs';

const sha = (s) => createHash('sha256').update(s).digest('hex').slice(0, 12);
const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
const files = (dir, ext) => (existsSync(dir) ? readdirSync(dir).filter((f) => !ext || f.endsWith(ext)).map((f) => join(dir, f)).filter((f) => statSync(f).isFile()) : []);

function art(kind, path, cls, scope, action, detail = {}, content = null) {
  return { kind, path, class: cls, scope, action, ...detail, ...(content != null ? { bytes: Buffer.byteLength(content), hash: sha(content) } : {}) };
}

// Split a markdown rules file into top-level sections (## …); the H1 becomes the
// preamble section. Each section is one rule candidate.
export function sectionsOf(markdown, { max = 40, maxChars = 1500 } = {}) {
  const out = [];
  let cur = { title: '(preamble)', lines: [] };
  for (const line of markdown.split('\n')) {
    const m = /^##\s+(.+)$/.exec(line);
    if (m) { if (cur.lines.join('\n').trim()) out.push(cur); cur = { title: m[1].trim(), lines: [] }; }
    else if (/^#\s+/.test(line)) { cur.title = line.replace(/^#\s+/, '').trim(); }
    else cur.lines.push(line);
  }
  if (cur.lines.join('\n').trim()) out.push(cur);
  return out.slice(0, max).map((s) => ({ title: s.title, content: s.lines.join('\n').trim().slice(0, maxChars) })).filter((s) => s.content && !/autoDev POINTER/.test(s.content));
}

// PRD → { title, spec, acceptance_criteria[] } (specs/<slug>/prd.md per reference/prd.md)
export function parsePrd(markdown) {
  const title = (/^#\s+(.+)$/m.exec(markdown) || [])[1]?.trim() || null;
  const ac = [];
  const sec = sectionsOf(markdown, { max: 100, maxChars: 20000 }).find((s) => /^acceptance criteria/i.test(s.title));
  if (sec) for (const l of sec.content.split('\n')) { const b = /^\s*(?:[-*]|\d+[.)])\s+(.+)$/.exec(l); if (b) ac.push(b[1].replace(/^\[[ x]\]\s*/i, '').trim()); }
  return { title, spec: markdown.trim(), acceptance_criteria: ac };
}

export function discoverProject(root) {
  const A = [];
  const rel = (p) => relative(root, p);
  // --- team convention docs: portable (rules) — and READ-ONLY to autoDev forever
  for (const f of ['CLAUDE.md', 'AGENTS.md', '.claude/CLAUDE.md']) {
    const p = join(root, f); const c = read(p); if (c == null) continue;
    const pointer = /autoDev POINTER/.test(c);
    A.push(art(pointer ? 'identity-pointer' : 'team-docs', rel(p), pointer ? 'legacy' : 'portable', 'project', pointer ? 'leave (our own v2 pointer; not a rule source)' : 'import as rule candidates (Brain, project scope); file left untouched', { sections: pointer ? 0 : sectionsOf(c).length }, c));
  }
  // --- autoDev v2 state
  const dep = join(root, '.autodev', 'deployment.json');
  if (existsSync(dep)) {
    const c = read(dep); let cfg = {}; try { cfg = JSON.parse(c); } catch {}
    A.push(art('deployment-config', rel(dep), 'portable', 'project', 'normalize → sidecar deployment.json; original left', { tracker: cfg.tracker?.kind || 'linear', planning: cfg.planning?.engine || (cfg.braingrid?.enabled ? 'braingrid (legacy flag)' : 'agency') }, c));
    if (cfg.braingrid?.enabled || cfg.braingrid?.project_short_id) A.push(art('braingrid-config', `${rel(dep)}#braingrid`, 'legacy', 'project', 'kept in the deployment copy; planning.engine decides', { project_short_id: cfg.braingrid?.project_short_id || null }));
    if (cfg.tracker?.kind === 'linear' || cfg.tracker?.team_id) A.push(art('linear-mapping', `${rel(dep)}#tracker`, 'legacy', 'project', 'kept as external refs; local tracker is the v3 default', { team: cfg.tracker?.team || null, mirror: !!cfg.tracker?.mirror?.linear }));
  }
  const local = join(root, '.autodev', 'deployment.local.json');
  if (existsSync(local)) A.push(art('deployment-local', rel(local), 'portable', 'project', 'machine-local paths; the sidecar registry already knows this clone', {}, read(local)));
  const board = join(root, '.autodev', 'board');
  if (existsSync(board)) {
    const issues = files(board, '.json').filter((f) => !basename(f).startsWith('_') && !basename(f).startsWith('.'));
    let features = 0, linear = 0, braingrid = 0;
    for (const f of issues) { try { const i = JSON.parse(read(f)); if ((i.labels || []).some((l) => /^route:feature$/.test(l))) features++; if (i.linear_id) linear++; if (/BrainGrid/.test(i.description || '')) braingrid++; } catch {} }
    A.push(art('board', rel(board), 'portable', 'project', 'copy → sidecar board (state repo); repo-local board left', { issues: issues.length, features, linear_mirrored: linear, braingrid_refs: braingrid }));
    if (existsSync(join(board, '.mirror-queue.jsonl'))) A.push(art('mirror-queue', rel(join(board, '.mirror-queue.jsonl')), 'legacy', 'project', 'left; flush it with tracker.mjs flush-mirror before switching', {}));
  }
  for (const [name, kind, cls, action] of [['conventions.md', 'conventions', 'portable', 'import as convention observations (Brain); file left'], ['metrics.jsonl', 'metrics', 'legacy', 'left (v2 adherence metrics)'], ['.docs_reconciled', 'marker', 'legacy', 'left'], ['.test_db_seeded', 'marker', 'legacy', 'left'], ['.backlog_authorized', 'marker', 'legacy', 'left'], ['board.html', 'board-html', 'legacy', 'left (regenerated)'], ['env.sh', 'env-script', 'vendor-specific', 'left; a sidecar deployment has no place for shell env — set commands.* instead']]) {
    const p = join(root, '.autodev', name); if (existsSync(p)) A.push(art(kind, rel(p), cls, 'project', action, {}, read(p)));
  }
  if (existsSync(join(root, '.autodev', 'engine'))) A.push(art('vendored-engine', '.autodev/engine', 'legacy', 'project', 'left; scripts/migrate-vendored.sh removes it (separate explicit cleanup)', {}));
  if (existsSync(join(root, '.autodev', 'backup-vendored'))) A.push(art('vendored-backup', '.autodev/backup-vendored', 'legacy', 'project', 'left', {}));
  // --- specs
  const specs = join(root, 'specs');
  if (existsSync(specs)) for (const slug of readdirSync(specs)) {
    const d = join(specs, slug); if (!statSync(d).isDirectory()) continue;
    const prd = read(join(d, 'prd.md')), brief = read(join(d, 'brief.md'));
    if (prd) { const p = parsePrd(prd); A.push(art('prd', rel(join(d, 'prd.md')), 'portable', 'project', 'import as a Brain requirement (spec + acceptance criteria); file left', { slug, title: p.title, acceptance_criteria: p.acceptance_criteria.length }, prd)); }
    if (brief) A.push(art('brief', rel(join(d, 'brief.md')), 'portable', 'project', prd ? 'context for the requirement; left' : 'import as a requirement note; left', { slug }, brief));
  }
  // --- Claude Code project configuration
  const cl = join(root, '.claude');
  for (const f of files(join(cl, 'commands'), '.md')) A.push(art('command', rel(f), 'adaptable', 'executor', 'left; Claude slash command — v3 equivalents are autodev CLI commands', {}, read(f)));
  for (const f of files(join(cl, 'agents'), '.md')) A.push(art('agent', rel(f), 'adaptable', 'project', 'adopt into the Agency persona store (copy); file left', {}, read(f)));
  for (const f of files(join(cl, 'skills'), '.md')) A.push(art('skill', rel(f), 'adaptable', 'executor', 'left; skills stay executor-side (M8A generates executor instructions per job)', {}, read(f)));
  const settings = read(join(cl, 'settings.json'));
  if (settings != null) {
    let s = {}; try { s = JSON.parse(settings); } catch {}
    const hooks = Object.values(s.hooks || {}).flat().flatMap((h) => h.hooks || []).length;
    const perms = (s.permissions?.allow || []).length + (s.permissions?.deny || []).length;
    A.push(art('claude-settings', rel(join(cl, 'settings.json')), 'vendor-specific', 'executor', 'left; permissions + hooks are Claude semantics (autoDev guards them in core)', { hooks, permissions: perms }, settings));
  }
  const mcp = read(join(root, '.mcp.json'));
  if (mcp != null) { let m = {}; try { m = JSON.parse(mcp); } catch {} A.push(art('mcp-config', '.mcp.json', 'adaptable', 'executor', 'left; MCP servers are per-executor (Brain will be one of them, M17)', { servers: Object.keys(m.mcpServers || {}) }, mcp)); }
  // --- git history: the last shipped work as learnings context (read-only)
  const log = git(root, ['log', '--format=%h%x1f%s', '-n', '30']);
  if (log) A.push(art('git-history', '.git (log)', 'portable', 'project', 'referenced (Git stays canonical); not copied', { commits: log.split('\n').filter(Boolean).length }));
  const branches = (git(root, ['branch', '--list', 'feature/*', 'autodev/*']) || '').split('\n').map((b) => b.replace(/^\*?\s*/, '')).filter(Boolean);
  if (branches.length) A.push(art('branches', '.git (branches)', 'portable', 'project', 'in flight — listed in the report, continue from them', { branches }));
  return A;
}

export function discoverUser(home = homedir()) {
  const A = [];
  const cl = join(home, '.claude');
  const md = read(join(cl, 'CLAUDE.md'));
  if (md != null) A.push(art('user-rules', '~/.claude/CLAUDE.md', 'portable', 'user', 'CANDIDATE user rules — imported only with --import-user, as user-scope observations (promotion is a separate human decision)', { sections: sectionsOf(md).length }, md));
  const agents = files(join(cl, 'agents'), '.md');
  if (agents.length) A.push(art('user-agents', '~/.claude/agents', 'adaptable', 'user', 'potential shared agents — `autodev agents sync` adopts them into the Agency store', { count: agents.length }));
  const cmds = files(join(cl, 'commands'), '.md');
  if (cmds.length) A.push(art('user-commands', '~/.claude/commands', 'adaptable', 'executor', 'left; Claude-specific', { count: cmds.length }));
  const settings = read(join(cl, 'settings.json'));
  if (settings != null) { let s = {}; try { s = JSON.parse(settings); } catch {} A.push(art('user-settings', '~/.claude/settings.json', 'vendor-specific', 'executor', 'left; Claude-specific (plugins, permissions, hooks)', { plugins: Object.keys(s.enabledPlugins || {}), hooks: Object.values(s.hooks || {}).flat().length })); }
  return A;
}
