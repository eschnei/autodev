#!/usr/bin/env node
// autodev — the developer-facing CLI (PRD §5). Installed with `npm link` during
// development (decision D1). Everything lives in src/cli/main.mjs; this file only
// exists so package.json's `bin` has a stable target.
import { main } from '../src/cli/main.mjs';

main(process.argv.slice(2)).then(
  (code) => { process.exitCode = code ?? 0; },
  (e) => { console.error(`autodev: ${e?.stack || e}`); process.exitCode = 1; },
);
