// autoDev — the existing-project translator (Milestone 14): `autodev migrate`.
//
// Non-destructive · dry-run capable · reversible · auditable (PRD §43).
//   READ   every repo + user artifact (discover.mjs)
//   IMPORT into Brain (rules, conventions, requirements) and the sidecar
//          (normalized deployment, board copy) — idempotent, keyed by content
//   LEAVE  every original untouched; the repo's git status is unchanged
// Removing legacy artifacts afterwards is a separate, explicit cleanup
// (scripts/migrate-vendored.sh for the vendored engine; nothing else is automated).

import { existsSync, readdirSync, readFileSync, writeFileSync, mkdirSync, copyFileSync } from 'node:fs';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { discoverProject, discoverUser, sectionsOf, parsePrd } from './discover.mjs';
import { normalize, validate } from '../core/config/schema.mjs';
import { projectDeploymentFile, projectBoardDir, projectDir, ensureProjectDirs, ensureAgentsDirs } from '../core/paths.mjs';
import { saveProject } from '../core/project.mjs';
import { appendEvent } from '../core/events.mjs';
import { StateRepo } from '../core/state.mjs';
import { PersonaStore } from '../agency/personas.mjs';

const sha = (s) => createHash('sha256').update(s).digest('hex').slice(0, 12);

export function plan(ctx, { home = homedir() } = {}) {
  const project = discoverProject(ctx.identity.root);
  const user = discoverUser(home);
  const counts = (arr) => Object.fromEntries(['portable', 'adaptable', 'vendor-specific', 'legacy'].map((c) => [c, arr.filter((a) => a.class === c).length]));
  return { project_id: ctx.project.id, repo: ctx.identity.root, artifacts: { project, user }, counts: { project: counts(project), user: counts(user) }, already_migrated: ctx.project.migrated || null };
}

// Applies the plan. `brain` is a connected brainStatus (or null → Brain steps skipped
// and reported). Returns what happened; writes a report under the sidecar.
export async function apply(ctx, p, { brain = null, importUser = false, log = () => {} } = {}) {
  const root = ctx.identity.root;
  const done = { sidecar: [], brain: [], agency: [], skipped: [], candidates: [] };
  const pid = ctx.project.id;
  ensureProjectDirs(pid);

  // ---- sidecar: deployment (normalized) + board copy ----
  const dep = p.artifacts.project.find((a) => a.kind === 'deployment-config');
  if (dep) {
    const rawText = readFileSync(join(root, dep.path), 'utf8');
    const raw = JSON.parse(rawText);
    const dest = projectDeploymentFile(pid);
    let existing = null; try { existing = JSON.parse(readFileSync(dest, 'utf8')); } catch {}
    if (existing?._migrated?.source_hash === sha(rawText)) {
      done.sidecar.push({ unchanged: dest, from: dep.path, valid: true, errors: [], warnings: 0, note: 'legacy file unchanged since the last migration — sidecar copy kept (your edits to it stand)' });
    } else {
      const { cfg, notes } = normalize(raw);
      const strip = (o) => Array.isArray(o) ? o.map(strip) : o && typeof o === 'object' ? Object.fromEntries(Object.entries(o).filter(([k]) => !k.startsWith('_')).map(([k, v]) => [k, strip(v)])) : o;
      const out = strip(cfg);
      delete out.repo?.local_path; delete out.runner; delete out.engine;
      out.tracker = { ...out.tracker, kind: 'local' };            // v3: the sidecar board is local; Linear/Shortcut stay as mirrors/refs
      // v3-only sections the legacy file cannot carry survive a re-migration
      if (existing?.brain) out.brain = existing.brain;
      if (existing?.executor) out.executor = existing.executor;
      out._migrated = { from: dep.path, at: new Date().toISOString(), notes, original_tracker: raw.tracker?.kind || 'linear', source_hash: sha(rawText) };
      const v = validate(out);
      writeFileSync(dest, JSON.stringify(out, null, 2) + '\n');
      done.sidecar.push({ wrote: dest, from: dep.path, valid: v.ok, errors: v.errors, warnings: v.warnings.length });
    }
  } else done.skipped.push('no .autodev/deployment.json — nothing to normalize (autodev init creates a v3 deployment)');
  const board = p.artifacts.project.find((a) => a.kind === 'board');
  if (board) {
    const src = join(root, board.path), dst = projectBoardDir(pid); mkdirSync(dst, { recursive: true });
    let copied = 0, kept = 0;
    for (const f of readdirSync(src)) {
      if (!f.endsWith('.json') && f !== '.counter') continue;
      const to = join(dst, f);
      if (existsSync(to) && readFileSync(to, 'utf8') === readFileSync(join(src, f), 'utf8')) { kept++; continue; }
      copyFileSync(join(src, f), to); copied++;
    }
    done.sidecar.push({ board: dst, copied, unchanged: kept, from: board.path });
  }
  // ---- agency: project-level agents into the store ----
  const agents = p.artifacts.project.filter((a) => a.kind === 'agent');
  if (agents.length) { ensureAgentsDirs(); const store = new PersonaStore(); const got = store.importFrom(join(root, '.claude', 'agents')); done.agency.push({ adopted: got, already: agents.length - got.length }); }

  // ---- Brain: rules, conventions, requirements (idempotent by content) ----
  if (brain?.state === 'connected' && brain.project_id) {
    const c = brain.client, bp = brain.project_id;
    const put = async (label, fn, key) => { try { const r = await fn(); done.brain.push({ [label]: r.id, replayed: !!r.replayed, key }); } catch (e) { done.brain.push({ [label]: null, error: e.message, key }); } };
    for (const a of p.artifacts.project.filter((x) => x.kind === 'team-docs')) {
      const secs = sectionsOf(readFileSync(join(root, a.path), 'utf8'));
      for (const s of secs) {
        const key = `migrate:${pid}:rule:${a.path}:${sha(s.title + s.content)}`;
        await put('rule', () => c.remember({ project_id: bp, type: 'rule', state: 'candidate', content: `${s.title}: ${s.content}`, provenance: [{ type: 'documentation', source: a.path }], data: { migrated_from: a.path, section: s.title } }, { idempotencyKey: key }), key);
      }
    }
    const conv = p.artifacts.project.find((x) => x.kind === 'conventions');
    if (conv) for (const s of sectionsOf(readFileSync(join(root, conv.path), 'utf8'), { max: 12 })) {
      const key = `migrate:${pid}:convention:${sha(s.title + s.content)}`;
      await put('convention', () => c.remember({ project_id: bp, type: 'convention', state: 'observation', content: `${s.title}: ${s.content}`, provenance: [{ type: 'repository', source: conv.path }], data: { migrated_from: conv.path } }, { idempotencyKey: key }), key);
    }
    for (const a of p.artifacts.project.filter((x) => x.kind === 'prd')) {
      const prd = parsePrd(readFileSync(join(root, a.path), 'utf8'));
      const key = `migrate:${pid}:req:${a.slug}:${sha(prd.spec)}`;
      await put('requirement', () => c.createRequirement(bp, { key: a.slug, title: prd.title || a.slug, spec: prd.spec, acceptance_criteria: prd.acceptance_criteria, external_refs: { spec_path: a.path } }, { idempotencyKey: key }), key);
    }
    if (board) for (const f of readdirSync(join(root, board.path)).filter((x) => /^AD-\d+\.json$/.test(x))) {
      let i; try { i = JSON.parse(readFileSync(join(root, board.path, f), 'utf8')); } catch { continue; }
      if (!(i.labels || []).includes('route:feature')) continue;
      const key = `migrate:${pid}:req:${i.id}:${sha(i.title + (i.description || ''))}`;
      await put('requirement', () => c.createRequirement(bp, { key: i.id, title: i.title, spec: i.description || '', acceptance_criteria: parsePrd(i.description || '').acceptance_criteria, external_refs: { legacy_autodev: i.id, ...(i.linear_id ? { linear: i.linear_id } : {}) } }, { idempotencyKey: key }), key);
    }
    const userRules = p.artifacts.user.find((x) => x.kind === 'user-rules');
    if (userRules) {
      const secs = sectionsOf(readFileSync(join(homedir(), '.claude', 'CLAUDE.md'), 'utf8'));
      if (importUser) for (const s of secs) {
        const key = `migrate:user:rule:${sha(s.title + s.content)}`;
        const uid = brain.user_id || brain.client?.info?.user_id || (await c.get('/v1')).user_id;
        await put('user-rule', () => c.remember({ scope: { type: 'user', id: uid }, type: 'rule', state: 'observation', visibility: 'user', content: `${s.title}: ${s.content}`, provenance: [{ type: 'documentation', source: '~/.claude/CLAUDE.md' }] }, { idempotencyKey: key }), key);
      } else done.candidates.push(...secs.map((s) => ({ kind: 'user-rule', title: s.title, preview: s.content.slice(0, 120) })));
    }
  } else {
    done.skipped.push(`Brain: ${brain && brain.state !== 'off' ? brain.state : 'not configured'} — rules, conventions, requirements not imported (re-run with Brain connected; every import is idempotent)`);
    const userRules = p.artifacts.user.find((x) => x.kind === 'user-rules');
    if (userRules) done.candidates.push(...sectionsOf(readFileSync(join(homedir(), '.claude', 'CLAUDE.md'), 'utf8')).map((s) => ({ kind: 'user-rule', title: s.title, preview: s.content.slice(0, 120) })));
  }

  // ---- mark the project migrated; the sidecar deployment now wins over the legacy file ----
  ctx.project.migrated = { at: new Date().toISOString(), from: 'claude', deployment: dep ? dep.path : null, board_copied: !!board };
  if (dep) ctx.project.tracker = { kind: 'local', location: projectBoardDir(pid), mode: 'sidecar' };
  saveProject(ctx.project, undefined, { commit: false });
  const reportDir = join(projectDir(pid), 'migrations'); mkdirSync(reportDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const report = { ...p, applied: done, at: new Date().toISOString() };
  writeFileSync(join(reportDir, `${stamp}.json`), JSON.stringify(report, null, 2) + '\n');
  writeFileSync(join(reportDir, `${stamp}.md`), renderReport(report));
  new StateRepo().commit(`project ${pid}: migrated from claude`);
  appendEvent(pid, { type: 'migration.applied', from: 'claude', sidecar: done.sidecar.length, brain: done.brain.length, agency: done.agency.length, report: `${stamp}.md` });
  return { ...done, report: join(reportDir, `${stamp}.md`) };
}

export function renderReport(r) {
  const row = (a) => `| ${a.class} | ${a.scope} | \`${a.path}\` | ${a.kind}${a.sections != null ? ` (${a.sections} sections)` : ''}${a.issues != null ? ` (${a.issues} issues, ${a.features} features)` : ''}${a.acceptance_criteria != null ? ` (${a.acceptance_criteria} criteria)` : ''}${a.branches ? ` (${a.branches.join(', ')})` : ''}${a.servers ? ` (${a.servers.join(', ') || 'none'})` : ''} | ${a.action} |`;
  const lines = [`# autoDev migration report — ${r.repo}`, '', `Project: ${r.project_id}${r.already_migrated ? ` (previously migrated ${r.already_migrated.at})` : ''}`, r.applied ? `Applied: ${r.at}` : '**DRY RUN — nothing was written.**', '',
    '## What migration does', '', 'READ every artifact below → IMPORT the portable ones into the sidecar + Brain → LEAVE every original untouched. Nothing is deleted; the repository\'s git status does not change. Removing legacy artifacts is a separate, explicit cleanup.', '',
    '## Project artifacts', '', `portable ${r.counts.project.portable} · adaptable ${r.counts.project.adaptable} · vendor-specific ${r.counts.project['vendor-specific']} · legacy ${r.counts.project.legacy}`, '', '| class | scope | artifact | kind | action |', '|---|---|---|---|---|', ...r.artifacts.project.map(row), '',
    '## User-level Claude configuration (candidates, never silently imported)', '', ...(r.artifacts.user.length ? ['| class | scope | artifact | kind | action |', '|---|---|---|---|---|', ...r.artifacts.user.map(row)] : ['(none found)']), ''];
  if (r.applied) {
    const d = r.applied;
    lines.push('## Applied', '', ...d.sidecar.map((s) => `- sidecar: ${s.wrote ? `wrote ${s.wrote} from ${s.from} (${s.valid ? 'valid' : `INVALID: ${s.errors.join('; ')}`}${s.warnings ? `, ${s.warnings} warning(s)` : ''})` : s.note ? `${s.unchanged}: ${s.note}` : `board ${s.board}: ${s.copied} copied, ${s.unchanged} unchanged (from ${s.from})`}`),
      ...d.agency.map((a) => `- agency: adopted ${a.adopted.length} persona(s)${a.already ? `, ${a.already} already in the store` : ''}`),
      ...(d.brain.length ? [`- brain: ${d.brain.filter((b) => !b.error).length} import(s) (${d.brain.filter((b) => b.replayed).length} already present, replayed idempotently)${d.brain.some((b) => b.error) ? `; ${d.brain.filter((b) => b.error).length} failed` : ''}`] : []),
      ...d.brain.filter((b) => b.error).map((b) => `  - failed: ${Object.keys(b)[0]} ${b.key} — ${b.error}`),
      ...d.skipped.map((s) => `- skipped: ${s}`), '');
    if (d.candidates.length) lines.push('## Candidates awaiting your decision', '', ...d.candidates.map((c) => `- ${c.kind}: **${c.title}** — ${c.preview}${c.preview.length >= 120 ? '…' : ''}`), '', 'Import them as user-scope observations with `autodev migrate --import-user`; promote to canonical later via Brain.', '');
    lines.push('## Next', '', '- `autodev status` now reads the sidecar deployment + board; the plugin path keeps reading `.autodev/` in the repo until you retire it.', '- Legacy cleanup is explicit: `scripts/migrate-vendored.sh` for a vendored engine; delete `.autodev/` yourself when the v3 board has proven itself.', '');
  }
  return lines.join('\n');
}
