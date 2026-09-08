// autoDev — where machine-local state lives (decision D2, docs/v3/decisions.md).
//
// v3 runtime state is sidecar: never inside the application repository. The root
// is the platform's user application-data directory, overridable with $AUTODEV_HOME
// (tests point it at a sandbox; a shared runner host can point it at a volume).
//
//   macOS   ~/Library/Application Support/autoDev
//   Linux   $XDG_DATA_HOME/autodev  (default ~/.local/share/autodev)
//   other   ~/.autodev-data
//
// Layout under the root:
//   state/                               ONE git repo = workflow reality, synced to a
//   state/registry.json                  private remote (src/core/state.mjs)
//   state/projects/<id>/project.json     identity + metadata
//   state/projects/<id>/deployment.json  v3-native deployment config (sidecar projects)
//   state/projects/<id>/board/           the board (sidecar projects)
//   state/projects/<id>/events/          append-only history
//   state/projects/<id>/runtime/         heartbeat, pause file, logs (git-ignored)
//   state/projects/<id>/locks/           (git-ignored)
//   agents/                              the Agency store (roles overrides, personas)

import { homedir, platform } from 'node:os';
import { join } from 'node:path';
import { mkdirSync, existsSync, renameSync } from 'node:fs';

export function dataRoot(env = process.env) {
  if (env.AUTODEV_HOME) return env.AUTODEV_HOME;
  const home = env.HOME || homedir();
  if (platform() === 'darwin') return join(home, 'Library', 'Application Support', 'autoDev');
  if (platform() === 'linux') return join(env.XDG_DATA_HOME || join(home, '.local', 'share'), 'autodev');
  return join(home, '.autodev-data');
}

export function stateDir(env) {
  const root = dataRoot(env); const state = join(root, 'state');
  // one-time layout move: the first v3 builds kept projects/ + registry.json at the root
  if (!existsSync(state) && (existsSync(join(root, 'projects')) || existsSync(join(root, 'registry.json')))) {
    mkdirSync(state, { recursive: true });
    for (const f of ['projects', 'registry.json']) if (existsSync(join(root, f))) renameSync(join(root, f), join(state, f));
  }
  return state;
}
export function registryPath(env) { return join(stateDir(env), 'registry.json'); }
export function projectDir(projectId, env) { return join(stateDir(env), 'projects', projectId); }
export function projectFile(projectId, env) { return join(projectDir(projectId, env), 'project.json'); }
export function projectDeploymentFile(projectId, env) { return join(projectDir(projectId, env), 'deployment.json'); }
export function projectBoardDir(projectId, env) { return join(projectDir(projectId, env), 'board'); }
export function projectRuntimeDir(projectId, env) { return join(projectDir(projectId, env), 'runtime'); }

export const PROJECT_SUBDIRS = Object.freeze(['board', 'events', 'locks', 'runtime']);

// The canonical, executor-neutral Agency store (Milestone 6): role overrides and
// persona definitions. NOT ~/.claude/agents — that directory is one executor's
// projection of this store (src/executors/claude/agents.mjs).
//   agents/roles/<role-id>.json     per-machine overrides of the built-in roles
//   agents/personas/<slug>.md       persona instructions (markdown + frontmatter)
export function agentsDir(env) { return join(dataRoot(env), 'agents'); }
export function ensureAgentsDirs(env) {
  const dir = agentsDir(env);
  for (const d of ['roles', 'personas']) mkdirSync(join(dir, d), { recursive: true });
  return dir;
}

export function ensureProjectDirs(projectId, env) {
  const dir = projectDir(projectId, env);
  for (const d of PROJECT_SUBDIRS) mkdirSync(join(dir, d), { recursive: true });
  return dir;
}
