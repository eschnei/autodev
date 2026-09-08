// autoDev — core config interface (Milestone 4 wrap of scripts/lib/config.mjs +
// Milestone 5 schema). Every v3 module reads deployment config through here:
//
//   const { cfg, validation, notes, configPath, localConfigPath } = await loadDeployment(repoRoot)
//
// `cfg` is the merged (project + machine-local) config, normalized for legacy
// keys (planning.engine derived from braingrid.enabled, executor/brain defaults)
// and already validated. The legacy loader keeps owning file discovery and the
// project/local precedence rules so the v2 scripts and v3 core can never disagree.

import { join } from 'node:path';
import { existsSync } from 'node:fs';
import { normalize, validate, defaults, SCHEMA, STAGES, GATES } from './schema.mjs';

export { SCHEMA, STAGES, GATES, defaults, validate, normalize };

export class ConfigError extends Error {
  constructor(message, { code = 'CONFIG', errors = [] } = {}) { super(message); this.code = code; this.errors = errors; }
}

// Loads + normalizes + validates. Throws ConfigError with code NO_CONFIG when the repo
// has no deployment, INVALID_CONFIG when the file fails the schema (errors listed).
// Pass { strict: false } to get the validation result back instead of throwing.
export async function loadDeployment(repoRoot, { strict = true, configPath: explicit } = {}) {
  const configPath = explicit || join(repoRoot, '.autodev', 'deployment.json');
  if (!existsSync(configPath)) throw new ConfigError(`no ${configPath}`, { code: 'NO_CONFIG' });
  const { loadConfig } = await import('../../../scripts/lib/config.mjs');
  const prev = process.env.AUTODEV_CONFIG;
  process.env.AUTODEV_CONFIG = configPath;
  let raw;
  try { raw = loadConfig(); }
  catch (e) { throw new ConfigError(`${configPath}: ${e.message}`, { code: 'INVALID_CONFIG', errors: [e.message] }); }
  finally { if (prev === undefined) delete process.env.AUTODEV_CONFIG; else process.env.AUTODEV_CONFIG = prev; }
  if (!raw.cfg) throw new ConfigError(`no ${configPath}`, { code: 'NO_CONFIG' });

  const { cfg, notes } = normalize(raw.cfg);
  const validation = validate(cfg);
  if (strict && !validation.ok) throw new ConfigError(`${configPath} is invalid:\n  - ${validation.errors.join('\n  - ')}`, { code: 'INVALID_CONFIG', errors: validation.errors });
  return { cfg, validation, notes, configPath, localConfigPath: raw.localConfigPath, isLegacySplit: raw.isLegacySplit };
}

// Stage helpers every workflow module needs.
export function stageName(cfg, key) { return cfg.tracker?.statuses?.[key]?.name || STAGES[key]?.name || key; }
export function isHumanStage(key) { return STAGES[key]?.human === true; }
export function stageKeys() { return Object.keys(STAGES); }
