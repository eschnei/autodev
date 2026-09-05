// autoDev — project identity + the sidecar project registry (decisions D2/D3).
//
// A project is identified by a stable `prj_<ULID>` that never changes, associated
// with the repository through identity that survives moves and clones: the
// normalized origin remote, the root commit, and (last resort) the clone path.
// Registration writes ONLY under the autoDev data root (src/core/paths.mjs) —
// never into the application repository. `git status` stays clean (G9).
//
// Legacy `.autodev/deployment.json` deployments are read through the existing
// loader (scripts/lib/config.mjs) so a v2 repo registers with its client_name and
// keeps its board where it is until migration (M5A/M14).

import { existsSync, readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { hostname } from 'node:os';
import { spawnSync } from 'node:child_process';
import { newId, isId } from './ids.mjs';
import { registryPath, projectFile, ensureProjectDirs } from './paths.mjs';

function git(cwd, ...args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() : null;
}

// git@github.com:Org/Repo.git · https://github.com/org/repo/ · ssh://git@host/org/repo
// → github.com/org/repo  (so every clone of one repository shares one fingerprint)
export function normalizeRemote(url) {
  if (!url) return null;
  let u = url.trim();
  const scp = /^[\w.-]+@([\w.-]+):(.+)$/.exec(u);
  if (scp) u = `${scp[1]}/${scp[2]}`;
  else u = u.replace(/^[a-z+]+:\/\//i, '').replace(/^[^@/]+@/, '');
  u = u.replace(/:\d+\//, '/').replace(/\.git\/?$/i, '').replace(/\/+$/, '');
  return u.toLowerCase();
}

export function repoIdentity(cwd = process.cwd()) {
  const root = git(cwd, 'rev-parse', '--show-toplevel');
  if (!root) return null;
  const remoteRaw = git(root, 'remote', 'get-url', 'origin');
  const rootCommits = git(root, 'rev-list', '--max-parents=0', 'HEAD');
  const branch = git(root, 'rev-parse', '--abbrev-ref', 'HEAD');
  return {
    root,
    remote: normalizeRemote(remoteRaw),
    remote_raw: remoteRaw,
    root_commit: rootCommits ? rootCommits.split('\n').sort()[0] : null,
    branch: branch === 'HEAD' ? null : branch,
    name: remoteRaw ? normalizeRemote(remoteRaw).split('/').pop() : root.split('/').pop(),
  };
}

// ---- registry ---------------------------------------------------------------------
function readJson(p, fallback) {
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return fallback; }
}
function writeJsonAtomic(p, obj) {
  mkdirSync(dirname(p), { recursive: true });
  const tmp = `${p}.tmp`;
  writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n');
  renameSync(tmp, p);
}

export function loadRegistry(env) {
  return readJson(registryPath(env), { version: 1, projects: [] });
}
function saveRegistry(reg, env) { writeJsonAtomic(registryPath(env), reg); }

export function findProject(identity, env, reg = loadRegistry(env)) {
  const byRemote = identity.remote && reg.projects.find((p) => p.remote && p.remote === identity.remote);
  if (byRemote) return byRemote;
  const byRoot = identity.root_commit && reg.projects.find((p) => p.root_commit && p.root_commit === identity.root_commit);
  if (byRoot) return byRoot;
  return reg.projects.find((p) => (p.clones || []).some((c) => c.path === identity.root)) || null;
}

export function loadProject(projectId, env) {
  if (!isId(projectId, 'project')) throw new TypeError(`loadProject: "${projectId}" is not a project id`);
  return readJson(projectFile(projectId, env), null);
}

export function saveProject(project, env) {
  project.updated_at = new Date().toISOString();
  writeJsonAtomic(projectFile(project.id, env), project);
  return project;
}

// Register (or re-attach) the repository at `cwd`. Idempotent: the same repo, from
// any clone path, resolves to the same project id. Returns { project, identity,
// created }. Never touches the repository.
export function registerProject(cwd = process.cwd(), { name, legacy = null, env } = {}) {
  const identity = repoIdentity(cwd);
  if (!identity) throw new Error(`not a git repository: ${cwd}`);
  const reg = loadRegistry(env);
  let entry = findProject(identity, env, reg); // same object we save below — mutations must land
  let created = false;
  const now = new Date().toISOString();
  const clone = { path: identity.root, machine: hostname(), last_seen: now };

  if (!entry) {
    created = true;
    entry = {
      id: newId('project'),
      name: name || legacy?.client_name || identity.name,
      remote: identity.remote,
      root_commit: identity.root_commit,
      clones: [clone],
      created_at: now,
    };
    reg.projects.push(entry);
  } else {
    entry.remote = entry.remote || identity.remote;
    entry.root_commit = entry.root_commit || identity.root_commit;
    const seen = (entry.clones || []).find((c) => c.path === clone.path);
    if (seen) seen.last_seen = now; else (entry.clones ||= []).push(clone);
  }
  saveRegistry(reg, env);

  ensureProjectDirs(entry.id, env);
  const existing = loadProject(entry.id, env);
  const project = existing || {
    id: entry.id,
    type: 'project',
    name: entry.name,
    key: null,
    external_refs: {},
    repository: { remote: identity.remote, remote_raw: identity.remote_raw, root_commit: identity.root_commit, default_branch: legacy?.repo?.default_branch || null },
    clones: [],
    legacy: { deployment_json: null, client_name: null },
    brain: { enabled: false, project_id: null, url: null },
    executor: { default: 'claude' },
    planning: { engine: 'agency' },
    tracker: { kind: 'local', location: null },
    created_at: now,
  };
  project.clones = entry.clones;
  if (legacy?.configPath) {
    project.legacy = { deployment_json: legacy.configPath, client_name: legacy.client_name || null };
    project.tracker = { kind: legacy.tracker?.kind || 'local', location: legacy.tracker?.kind === 'local' || !legacy.tracker?.kind ? join(dirname(legacy.configPath), 'board') : null };
    if (legacy.repo?.default_branch) project.repository.default_branch = legacy.repo.default_branch;
  }
  saveProject(project, env);
  return { project, identity, created };
}

// The one call the CLI makes on start: identify the repo, load legacy config if
// present, register sidecar, and hand back everything the shell needs.
export async function resolveProject(cwd = process.cwd(), { env } = {}) {
  const identity = repoIdentity(cwd);
  if (!identity) return { identity: null, project: null, legacy: null, created: false };
  let legacy = null;
  const legacyPath = join(identity.root, '.autodev', 'deployment.json');
  if (existsSync(legacyPath)) {
    const { loadConfig } = await import('../../scripts/lib/config.mjs');
    const prev = process.cwd();
    try { process.chdir(identity.root); const r = loadConfig(); legacy = r.cfg ? { ...r.cfg, configPath: r.configPath, localConfigPath: r.localConfigPath, isLegacySplit: r.isLegacySplit } : null; }
    finally { process.chdir(prev); }
  }
  const { project, created } = registerProject(identity.root, { legacy, env });
  return { identity, project, legacy, created };
}
