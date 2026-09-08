// autoDev — Claude projection of the Agency (Milestone 6).
//
//   Agency role + persona (canonical, executor-neutral store)
//        │
//        ├── Claude representation  ← this file: ~/.claude/agents/<persona>.md subagents
//        ├── Codex representation   (M15)
//        └── future representation
//
// Claude Code discovers subagents as markdown files with frontmatter in its agents
// directory; agency-agents personas are already in that format, so projection is
// a faithful copy plus a manifest that lets us tell OUR projected files from a
// file the user authored or edited (those are never overwritten).

import { existsSync, readFileSync, writeFileSync, mkdirSync, renameSync } from 'node:fs';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { renderRoleBrief } from '../../agency/roles.mjs';
import { resolvePersonas } from '../../agency/personas.mjs';

const MANIFEST = '.autodev-projected.json';
const sha = (s) => createHash('sha256').update(s).digest('hex');

export function claudeAgentsDir(env = process.env) {
  return env.AUTODEV_AGENTS_DIR || join(env.HOME || homedir(), '.claude', 'agents');
}

function readManifest(dir) { try { return JSON.parse(readFileSync(join(dir, MANIFEST), 'utf8')); } catch { return { version: 1, files: {} }; } }
function writeManifest(dir, m) { const p = join(dir, MANIFEST); writeFileSync(`${p}.tmp`, JSON.stringify(m, null, 2) + '\n'); renameSync(`${p}.tmp`, p); }

// Project every persona this deployment needs from the store into Claude's agents
// dir. Rules: write when absent; rewrite when the target is byte-identical to what
// we projected last time (so store updates flow); leave a user-owned or user-edited
// file alone and report it. Never writes outside `targetDir`.
export function projectPersonas(cfg, store, { targetDir = claudeAgentsDir() } = {}) {
  mkdirSync(targetDir, { recursive: true });
  const manifest = readManifest(targetDir);
  const out = { written: [], updated: [], kept: [], missing: [], builtin: [] };
  for (const r of resolvePersonas(cfg, store)) {
    if (r.status === 'builtin') { out.builtin.push(r.slug); continue; }
    if (r.status !== 'installed') { out.missing.push(r.slug); continue; }
    const content = readFileSync(r.file, 'utf8');
    const file = basename(r.file);
    const dest = join(targetDir, file);
    const h = sha(content);
    if (!existsSync(dest)) {
      writeFileSync(`${dest}.tmp`, content); renameSync(`${dest}.tmp`, dest);
      manifest.files[file] = { slug: r.slug, sha256: h }; out.written.push(file);
    } else {
      const cur = sha(readFileSync(dest, 'utf8'));
      if (cur === h) { manifest.files[file] = { slug: r.slug, sha256: h }; out.kept.push(file); }
      else if (manifest.files[file]?.sha256 === cur) {
        writeFileSync(`${dest}.tmp`, content); renameSync(`${dest}.tmp`, dest);
        manifest.files[file] = { slug: r.slug, sha256: h }; out.updated.push(file);
      } else out.kept.push(`${file} (user-owned, not overwritten)`);
    }
  }
  writeManifest(targetDir, manifest);
  return out;
}

// The Claude-side prompt for a role: autoDev's role brief + the persona's own
// instructions. This is what a job's task is prefixed with when an executor runs
// a role (M8 jobs), so the persona carries the specialism and the role carries
// autoDev's rules — in that order.
export function renderRolePrompt(role, persona) {
  const parts = [renderRoleBrief(role)];
  if (persona?.body) parts.push('', `# Persona: ${persona.name || persona.slug}`, persona.body.trim());
  return parts.join('\n');
}
