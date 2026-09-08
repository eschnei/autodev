// autoDev — Agency personas: the specialist instruction sets (Milestone 6).
//
// A persona is markdown with a small frontmatter (name, description, and
// cosmetic/meta keys). That format is executor-neutral — it is just instructions —
// so the canonical store keeps the file as-is under <data root>/agents/personas/
// and each executor adapter projects it into whatever its runtime reads
// (Claude Code: ~/.claude/agents/<file>.md; a future Codex adapter: its own
// instruction format). Source library: agency-agents (MIT), pinned by ref in
// personas.library; fetching stays consent-gated by personas.auto_install.
//
// Mirrors scripts/ensure-personas.sh's resolution rules (bare `<slug>.md` or the
// library's `<division>-<slug>.md`) so the plugin path and the v3 path agree.

import { existsSync, readdirSync, readFileSync, writeFileSync, renameSync, mkdirSync, copyFileSync, statSync } from 'node:fs';
import { join, basename } from 'node:path';
import { agentsDir } from '../core/paths.mjs';

export const DIVISIONS = ['academic', 'design', 'engineering', 'gis', 'government', 'marketing', 'product', 'project-management', 'sales', 'specialized', 'testing'];
export const BUILTIN_PERSONAS = Object.freeze(['general-purpose']);   // provided by the executor itself
const SLUG_RE = /^[a-z0-9-]+$/;

// ---- format --------------------------------------------------------------------------
export function parsePersona(markdown) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(markdown);
  const meta = {};
  let body = markdown;
  if (m) {
    body = m[2];
    for (const line of m[1].split(/\r?\n/)) {
      const kv = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
      if (kv) meta[kv[1]] = kv[2].trim();
    }
  }
  const { name, description, ...rest } = meta;
  return { name: name || null, description: description || null, meta: rest, body };
}
export function renderPersona({ name, description, meta = {}, body = '' }) {
  const fm = [`name: ${name}`, ...(description ? [`description: ${description}`] : []), ...Object.entries(meta).map(([k, v]) => `${k}: ${v}`)];
  return `---\n${fm.join('\n')}\n---\n${body}`;
}

// ---- the store ----------------------------------------------------------------------
export class PersonaStore {
  #dir;
  constructor({ dir, env } = {}) { this.#dir = dir || join(agentsDir(env), 'personas'); }
  get dir() { return this.#dir; }

  // path of the file that provides `slug`, or null (bare name or division-prefixed)
  resolve(slug) {
    if (!SLUG_RE.test(slug) || !existsSync(this.#dir)) return null;
    const bare = join(this.#dir, `${slug}.md`);
    if (existsSync(bare)) return bare;
    for (const d of DIVISIONS) { const p = join(this.#dir, `${d}-${slug}.md`); if (existsSync(p)) return p; }
    return null;
  }
  has(slug) { return this.resolve(slug) !== null; }
  list() {
    if (!existsSync(this.#dir)) return [];
    return readdirSync(this.#dir).filter((f) => f.endsWith('.md')).map((f) => {
      const slug = f.replace(/\.md$/, '');
      const div = DIVISIONS.find((d) => slug.startsWith(`${d}-`));
      return { file: f, slug: div ? slug.slice(div.length + 1) : slug, division: div || null };
    });
  }
  read(slug) {
    const p = this.resolve(slug);
    if (!p) return null;
    return { slug, file: p, ...parsePersona(readFileSync(p, 'utf8')) };
  }
  write(slug, persona, { file } = {}) {
    if (!SLUG_RE.test(slug)) throw new Error(`persona slug "${slug}" is not [a-z0-9-]`);
    mkdirSync(this.#dir, { recursive: true });
    const dest = join(this.#dir, file || `${slug}.md`);
    const tmp = `${dest}.tmp`;
    writeFileSync(tmp, typeof persona === 'string' ? persona : renderPersona(persona));
    renameSync(tmp, dest);   // atomic — a concurrent reader never sees a half-written file
    return dest;
  }
  // Adopt persona files from another directory (e.g. an executor's agents dir that
  // predates the store). Never overwrites a store file; returns what was imported.
  importFrom(dir) {
    const imported = [];
    if (!existsSync(dir)) return imported;
    mkdirSync(this.#dir, { recursive: true });
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.md'))) {
      const dest = join(this.#dir, f);
      if (existsSync(dest)) continue;
      const src = join(dir, f);
      if (!statSync(src).isFile()) continue;
      copyFileSync(src, dest); imported.push(f);
    }
    return imported;
  }
}

// ---- what a deployment needs (same set scripts/ensure-personas.sh computes) ----------
export function neededSlugs(cfg) {
  const p = cfg.personas || {};
  const noNotes = (o) => Object.fromEntries(Object.entries(o || {}).filter(([k]) => !k.startsWith('_')));
  const set = new Set([
    ...(p.roster || []),
    ...Object.values(noNotes(p.stage_defaults)),
    ...(p.dev_routing || []).map((r) => r.persona),
    ...Object.values(noNotes(p.qa_angles)).flatMap((v) => (Array.isArray(v) ? v : [v])),
    p.fallback || 'general-purpose',
  ].filter((s) => typeof s === 'string' && s));
  return [...set].sort();
}

// Resolution report for a deployment against a store.
export function resolvePersonas(cfg, store) {
  return neededSlugs(cfg).map((slug) => {
    if (!SLUG_RE.test(slug)) return { slug, status: 'invalid' };
    if (BUILTIN_PERSONAS.includes(slug)) return { slug, status: 'builtin' };
    const file = store.resolve(slug);
    return file ? { slug, status: 'installed', file } : { slug, status: 'unresolved' };
  });
}

// ---- consent-gated install from the pinned library -------------------------------------
// `fetchImpl` is injectable (tests stub it); production uses global fetch (Node 18+).
export async function installPersona(slug, { store, repo = 'msitarzewski/agency-agents', ref = 'main', fetchImpl = globalThis.fetch, tree } = {}) {
  if (!SLUG_RE.test(slug)) return { slug, status: 'invalid' };
  if (store.has(slug)) return { slug, status: 'installed', file: store.resolve(slug) };
  let paths = tree;
  if (!paths) {
    const r = await fetchImpl(`https://api.github.com/repos/${repo}/git/trees/${ref}?recursive=1`);
    if (!r.ok) return { slug, status: 'unresolved', reason: `tree fetch ${r.status}` };
    paths = ((await r.json()).tree || []).map((t) => t.path);
  }
  // library layout is <division>/<division>-<slug>.md — require dirname/basename agreement
  const path = paths.find((p) => { const parts = p.split('/'); return (parts.length === 2 && parts[1] === `${parts[0]}-${slug}.md`) || (parts.length === 1 && parts[0] === `${slug}.md`); });
  if (!path) return { slug, status: 'unresolved', reason: 'not in library' };
  const raw = await fetchImpl(`https://raw.githubusercontent.com/${repo}/${ref}/${path}`);
  if (!raw.ok) return { slug, status: 'unresolved', reason: `fetch ${raw.status}` };
  const text = await raw.text();
  if (!text.trim()) return { slug, status: 'unresolved', reason: 'empty file' };
  const file = store.write(slug, text, { file: basename(path) });
  return { slug, status: 'downloaded', file, ref };
}

export async function ensurePersonas(cfg, { store, fetchImpl, check = false } = {}) {
  const auto = cfg.personas?.auto_install;
  const consent = auto === true || auto === undefined;   // non-boolean fails CLOSED (ensure-personas.sh rule)
  const report = [];
  let tree;
  for (const r of resolvePersonas(cfg, store)) {
    if (r.status !== 'unresolved' || check || !consent) { report.push(r); continue; }
    const lib = cfg.personas?.library || {};
    const res = await installPersona(r.slug, { store, repo: lib.repo, ref: lib.ref, fetchImpl, tree });
    report.push(res);
  }
  const n = (s) => report.filter((r) => r.status === s).length;
  return { report, needed: report.length, installed: n('installed') + n('builtin'), downloaded: n('downloaded'), unresolved: n('unresolved') + n('invalid'), fallback: cfg.personas?.fallback || 'general-purpose' };
}
