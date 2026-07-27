#!/usr/bin/env node
// autoDev — shared config loader (imported by tracker.mjs, linear.mjs, shortcut.mjs,
// report.mjs). Resolves the committed .autodev/deployment.json (project config) and
// merges in the never-committed local-override file, so precedence/merge rules live
// in exactly one place instead of duplicated per caller.
//
// Local file resolution (first found wins):
//   1. .autodev/deployment.local.json        (repo-local, gitignored)
//   2. ~/.config/autodev/<client_name>/deployment.local.json   (global fallback)
//   3. neither -> legacy fallback: read the local-only fields inline from
//      deployment.json itself (pre-split deployments keep working unmodified)
// $AUTODEV_LOCAL_CONFIG forces an explicit local-file path (mirrors $AUTODEV_CONFIG).

import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';

// Exclusively local — no equivalent value lives in deployment.json going forward.
// A value found here always wins; a value found inline in deployment.json (no local
// file covering it) sets isLegacySplit so callers can nudge the operator to migrate.
const LOCAL_ONLY_PATHS = [
  ['repo', 'local_path'],
  ['runner', 'home_dir'],
  ['runner', 'heartbeat_file'],
  ['runner', 'rate_limited_file'],
  ['runner', 'logs_dir'],
];

// Optional local overrides of a value that otherwise comes from deployment.json.
// Only applied when the local file sets a non-empty value.
const OVERRIDABLE_PATHS = [
  ['tracker', 'instance_label'],
  ['tracker', 'linear', 'api_token_file'],
  ['tracker', 'shortcut', 'api_token_file'],
];

function getIn(obj, pathArr) {
  let cur = obj;
  for (const key of pathArr) {
    if (cur == null || typeof cur !== 'object') return undefined;
    cur = cur[key];
  }
  return cur;
}

function setIn(obj, pathArr, value) {
  let cur = obj;
  for (let i = 0; i < pathArr.length - 1; i++) {
    const key = pathArr[i];
    if (typeof cur[key] !== 'object' || cur[key] === null) cur[key] = {};
    cur = cur[key];
  }
  cur[pathArr[pathArr.length - 1]] = value;
}

function findProjectConfig() {
  if (process.env.AUTODEV_CONFIG && existsSync(process.env.AUTODEV_CONFIG)) return process.env.AUTODEV_CONFIG;
  let dir = process.cwd();
  for (let i = 0; i < 12; i++) {
    const p = join(dir, '.autodev', 'deployment.json');
    if (existsSync(p)) return p;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

function findLocalConfig(projectConfigPath, projectCfg) {
  if (process.env.AUTODEV_LOCAL_CONFIG) {
    return existsSync(process.env.AUTODEV_LOCAL_CONFIG) ? process.env.AUTODEV_LOCAL_CONFIG : null;
  }
  if (projectConfigPath) {
    const repoLocal = join(dirname(projectConfigPath), 'deployment.local.json');
    if (existsSync(repoLocal)) return repoLocal;
  }
  const client = projectCfg?.client_name;
  if (client) {
    const globalLocal = join(homedir(), '.config', 'autodev', client, 'deployment.local.json');
    if (existsSync(globalLocal)) return globalLocal;
  }
  return null;
}

// Resolves deployment.json + its local override file and returns the merged config.
// Returns { cfg: null, ... } when no deployment.json is found — callers die with
// their own message (each script's wording differs slightly today; preserved as-is).
export function loadConfig() {
  const configPath = findProjectConfig();
  if (!configPath) return { cfg: null, configPath: null, localConfigPath: null, isLegacySplit: false };
  const cfg = JSON.parse(readFileSync(configPath, 'utf8'));
  const localConfigPath = findLocalConfig(configPath, cfg);
  const local = localConfigPath ? JSON.parse(readFileSync(localConfigPath, 'utf8')) : null;

  let isLegacySplit = false;
  for (const p of LOCAL_ONLY_PATHS) {
    const localVal = getIn(local, p);
    if (localVal !== undefined) {
      setIn(cfg, p, localVal);
    } else if (getIn(cfg, p) !== undefined) {
      isLegacySplit = true; // still inline in deployment.json — pre-split deployment
    }
  }
  for (const p of OVERRIDABLE_PATHS) {
    const localVal = getIn(local, p);
    if (localVal !== undefined && localVal !== '') setIn(cfg, p, localVal);
  }

  return { cfg, configPath, localConfigPath, isLegacySplit };
}
