// autoDev — canonical entity identity (decision D3, docs/v3/decisions.md).
//
// Every entity gets a globally unique, stable internal id: a typed prefix plus a
// ULID (48-bit ms timestamp + 80 random bits, Crockford base32, lexically sortable
// by creation time). Human-friendly keys (REQ-104) and tracker ids (AD-19, ENG-418)
// are aliases carried in `external_refs`, never the identity. Brain and autoDev
// share this scheme. No dependencies — it must run in the zero-dep plugin tree.

import { randomBytes } from 'node:crypto';

const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford: no I, L, O, U

export const PREFIXES = Object.freeze({
  user: 'usr', workspace: 'wks', project: 'prj', repository: 'repo',
  requirement: 'req', task: 'task', job: 'job', memory: 'mem', decision: 'dec',
  learning: 'lrn', handoff: 'hnd', relationship: 'rel', context: 'ctx', event: 'evt',
});

// A 26-char ULID. `time` is injectable for tests; production callers omit it.
export function ulid(time = Date.now()) {
  if (!Number.isInteger(time) || time < 0 || time > 0xffffffffffff) throw new RangeError(`ulid: bad time ${time}`);
  let out = '';
  let t = time;
  for (let i = 0; i < 10; i++) { out = ALPHABET[t % 32] + out; t = Math.floor(t / 32); }
  // 80 random bits → 16 chars of 5 bits. Draw 10 bytes and consume them 5 bits at a time.
  const rnd = randomBytes(10);
  let acc = 0, bits = 0, rand = '';
  for (const b of rnd) {
    acc = (acc << 8) | b; bits += 8;
    while (bits >= 5) { bits -= 5; rand += ALPHABET[(acc >>> bits) & 31]; }
  }
  return out + rand; // 10 + 16 = 26
}

export function newId(type, time) {
  const p = PREFIXES[type];
  if (!p) throw new TypeError(`newId: unknown entity type "${type}" (${Object.keys(PREFIXES).join(', ')})`);
  return `${p}_${ulid(time)}`;
}

const ID_RE = new RegExp(`^(${Object.values(PREFIXES).join('|')})_([0-9A-HJKMNP-TV-Z]{26})$`);

export function parseId(id) {
  const m = ID_RE.exec(String(id));
  if (!m) return null;
  const type = Object.keys(PREFIXES).find((k) => PREFIXES[k] === m[1]);
  return { type, prefix: m[1], ulid: m[2], time: ulidTime(m[2]) };
}

export function isId(id, type) {
  const p = parseId(id);
  return !!p && (type === undefined || p.type === type);
}

export function ulidTime(u) {
  let t = 0;
  for (const c of u.slice(0, 10)) t = t * 32 + ALPHABET.indexOf(c);
  return t;
}
