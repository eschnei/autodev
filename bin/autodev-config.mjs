#!/usr/bin/env node
// autoDev — config schema tooling for shell callers (doctor.sh, upgrade-config.sh, CI).
//
//   autodev-config validate [repo]        exit 0 ok / 1 errors; prints errors + warnings
//   autodev-config defaults               the schema defaults (non-identity, non-local) as JSON
//   autodev-config defaults --all         every default incl. identity/local fields
//   autodev-config normalize [repo]       the normalized effective config as JSON
//   autodev-config paths                  every leaf path the schema declares
import { loadDeployment, defaults, ConfigError } from '../src/core/config/index.mjs';
import { leafPaths } from '../src/core/config/schema.mjs';

const [cmd = 'validate', ...rest] = process.argv.slice(2);
const repo = rest.find((a) => !a.startsWith('--')) || process.cwd();

try {
  switch (cmd) {
    case 'validate': {
      const { validation, notes, configPath } = await loadDeployment(repo, { strict: false });
      for (const n of notes) console.log(`  · ${n}`);
      for (const w of validation.warnings) console.log(`  ! ${w}`);
      for (const e of validation.errors) console.log(`  ✗ ${e}`);
      console.log(validation.ok ? `  ✓ ${configPath} conforms to the schema${validation.warnings.length ? ` (${validation.warnings.length} warning(s))` : ''}` : `  ✗ ${configPath}: ${validation.errors.length} error(s)`);
      process.exitCode = validation.ok ? 0 : 1;
      break;
    }
    case 'defaults':
      console.log(JSON.stringify(rest.includes('--all') ? defaults({ identity: true, local: true }) : defaults({ identity: false, local: false }), null, 2));
      break;
    case 'normalize': {
      const { cfg } = await loadDeployment(repo, { strict: false });
      console.log(JSON.stringify(cfg, null, 2));
      break;
    }
    case 'paths':
      console.log(leafPaths().join('\n'));
      break;
    default:
      console.error(`autodev-config: unknown command "${cmd}" (validate | defaults | normalize | paths)`);
      process.exitCode = 2;
  }
} catch (e) {
  if (e instanceof ConfigError) { console.error(`  ✗ ${e.message}`); process.exitCode = e.code === 'NO_CONFIG' ? 3 : 1; }
  else throw e;
}
