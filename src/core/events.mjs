// autoDev — the sidecar event history (decision D2). Every meaningful workflow
// mutation autoDev core performs appends one event under
// <data root>/projects/<project-id>/events/<YYYY-MM>.jsonl. Append-only, one JSON
// object per line, each with a stable evt_<ULID> id so a retried write can be
// recognized (idempotency, PRD §66) and a later Brain sync (M13) can replay them.

import { appendFileSync, mkdirSync, readdirSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { hostname } from 'node:os';
import { newId } from './ids.mjs';
import { projectDir } from './paths.mjs';
import { stateCommit } from './state.mjs';

export function appendEvent(projectId, event, { env } = {}) {
  const dir = join(projectDir(projectId, env), 'events');
  mkdirSync(dir, { recursive: true });
  const at = new Date().toISOString();
  const evt = { id: newId('event'), at, client: `${hostname()}-autodev`, ...event };
  appendFileSync(join(dir, `${at.slice(0, 7)}.jsonl`), JSON.stringify(evt) + '\n');
  stateCommit(`event ${evt.type}${evt.issue ? ` ${evt.issue}` : ''}`, env);
  return evt;
}

export function readEvents(projectId, { env, type, issue } = {}) {
  const dir = join(projectDir(projectId, env), 'events');
  if (!existsSync(dir)) return [];
  const out = [];
  for (const f of readdirSync(dir).filter((x) => x.endsWith('.jsonl')).sort()) {
    for (const line of readFileSync(join(dir, f), 'utf8').split('\n')) {
      if (!line.trim()) continue;
      try { const e = JSON.parse(line); if ((!type || e.type === type) && (!issue || e.issue === issue)) out.push(e); } catch {}
    }
  }
  return out;
}
