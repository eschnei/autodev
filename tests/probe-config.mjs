#!/usr/bin/env node
// Test helper for scripts/lib/config.mjs — used by tests/smoke.sh.
// Usage: node probe-config.mjs <path-to-config.mjs> <repo-dir> <expectLocalPath> <expectLegacy true|false> [expectInstanceLabel]
import { pathToFileURL } from 'node:url';

const [, , libPath, repoDir, expectLocalPath, expectLegacy, expectInstanceLabel] = process.argv;
process.chdir(repoDir);
const { loadConfig } = await import(pathToFileURL(libPath).href);
const { cfg, isLegacySplit } = loadConfig();
if (!cfg) { console.error('loadConfig() returned no cfg'); process.exit(1); }

const gotLocalPath = cfg.repo?.local_path ?? '';
if (gotLocalPath !== expectLocalPath) {
  console.error(`repo.local_path: got "${gotLocalPath}" want "${expectLocalPath}"`); process.exit(1);
}
if (String(isLegacySplit) !== expectLegacy) {
  console.error(`isLegacySplit: got ${isLegacySplit} want ${expectLegacy}`); process.exit(1);
}
if (expectInstanceLabel !== undefined && cfg.tracker?.instance_label !== expectInstanceLabel) {
  console.error(`tracker.instance_label: got "${cfg.tracker?.instance_label}" want "${expectInstanceLabel}"`); process.exit(1);
}
console.log('ok');
