// autoDev — BrainClient (Milestone 13). autoDev's OWN client for the Brain HTTP
// API (autoDev depends on Brain's public contract, never on its code):
//   - version/capability negotiation on connect, clear failure on incompatibility
//   - bearer token resolved from the machine, never from deployment config:
//       $BRAIN_TOKEN → ~/.config/autodev/brain.token → macOS Keychain (service "brain")
//   - Idempotency-Key on every write autoDev retries (job ids, event ids)
//   - short timeouts so a Brain outage degrades instead of hanging a tick
//
// Everything Brain-specific on the wire lives here; the integration layer
// (src/brain/index.mjs) only speaks in bundles, handoffs, and decisions.

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir, hostname } from 'node:os';
import { spawnSync } from 'node:child_process';

export const REQUIRED_API = '>=1.0.0 <2.0.0';

export class BrainClientError extends Error { constructor(m, status = 0, code = 'http') { super(m); this.status = status; this.code = code; } }
export class BrainIncompatible extends BrainClientError { constructor(m) { super(m, 0, 'incompatible'); } }
export class BrainUnreachable extends BrainClientError { constructor(m) { super(m, 0, 'unreachable'); } }

export function satisfies(version, range) {
  const v = String(version).split('.').map(Number);
  const m = /^>=\s*(\d+)\.(\d+)\.(\d+)\s*<\s*(\d+)/.exec(range);
  if (!m) throw new Error(`bad range: ${range}`);
  const [, maj, min, pat, maxMaj] = m.map(Number);
  if (v[0] !== maj || v[0] >= maxMaj) return false;
  if (v[1] !== min) return v[1] > min;
  return v[2] >= pat;
}

// Token resolution — machine-local, never in the repo or deployment.json (PRD §51/§64).
export function resolveToken(env = process.env) {
  if (env.BRAIN_TOKEN) return { token: env.BRAIN_TOKEN, source: 'env' };
  const file = join(env.HOME || homedir(), '.config', 'autodev', 'brain.token');
  if (existsSync(file)) { const t = readFileSync(file, 'utf8').split('\n')[0].trim().split(/\s+/)[0]; if (t) return { token: t, source: file }; }
  if (process.platform === 'darwin' && env.AUTODEV_NO_KEYCHAIN !== '1') {
    const r = spawnSync('security', ['find-generic-password', '-s', 'brain', '-w'], { encoding: 'utf8' });
    if (r.status === 0 && r.stdout.trim()) return { token: r.stdout.trim(), source: 'keychain' };
  }
  return { token: null, source: null };
}

export function clientIdentity(env = process.env) {
  return env.AUTODEV_BRAIN_CLIENT || `${hostname().split('.')[0]}-autoDev`;
}

export class BrainClient {
  #url; #token; #fetch; #id; #timeout; #info = null;
  constructor({ url, token, fetchImpl = globalThis.fetch, clientId = clientIdentity(), timeoutMs = 5000, requireApi = REQUIRED_API } = {}) {
    if (!url) throw new BrainClientError('brain.url is not configured', 0, 'config');
    this.#url = url.replace(/\/+$/, ''); this.#token = token; this.#fetch = fetchImpl; this.#id = clientId; this.#timeout = timeoutMs;
    this.requireApi = requireApi;
  }
  get url() { return this.#url; }
  get info() { return this.#info; }
  get clientId() { return this.#id; }

  async #raw(method, path, body, headers = {}) {
    let r;
    try {
      r = await this.#fetch(`${this.#url}${path}`, { method, headers: { Accept: 'application/json', ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}), ...headers }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(this.#timeout) });
    } catch (e) { throw new BrainUnreachable(`Brain at ${this.#url} unreachable: ${e.cause?.code || e.name || e.message}`); }
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new BrainClientError(data.message || `HTTP ${r.status}`, r.status, data.error || 'http');
    return data;
  }
  async connect() {
    const info = await this.#raw('GET', '/v1');
    if (!satisfies(info.api, this.requireApi)) throw new BrainIncompatible(`Brain connected but incompatible. Required: ${this.requireApi}. Detected: ${info.api}`);
    this.#info = info;
    return info;
  }
  has(cap) { return !!this.#info?.capabilities?.includes(cap); }
  async call(method, path, body, { idempotencyKey } = {}) {
    if (!this.#info) await this.connect();
    const headers = { 'X-Brain-Client': this.#id, 'X-Brain-Client-Kind': 'agent' };
    if (this.#token) headers.Authorization = `Bearer ${this.#token}`;
    if (idempotencyKey) headers['Idempotency-Key'] = idempotencyKey;
    return this.#raw(method, path, body, headers);
  }
  get(p) { return this.call('GET', p); }
  post(p, b, o) { return this.call('POST', p, b, o); }
  patch(p, b) { return this.call('PATCH', p, b); }

  health() { return this.#raw('GET', '/v1/health'); }
  project(idOrKey) { return this.get(`/v1/projects/${encodeURIComponent(idOrKey)}`); }
  createProject(p, o) { return this.post('/v1/projects', p, o); }
  registerRepository(projectId, repo) { return this.post(`/v1/projects/${encodeURIComponent(projectId)}/repositories`, repo); }
  requirements(projectId) { return this.get(`/v1/projects/${encodeURIComponent(projectId)}/requirements`); }
  createRequirement(projectId, r, o) { return this.post(`/v1/projects/${encodeURIComponent(projectId)}/requirements`, r, o); }
  context(ctx) { return this.post('/v1/context', ctx); }
  search(params) { return this.get(`/v1/search?${new URLSearchParams(Object.entries(params).filter(([, v]) => v != null))}`); }
  handoff(h, o) { return this.post('/v1/handoffs', h, o); }
  latestHandoff(params) { return this.get(`/v1/handoffs/latest?${new URLSearchParams(Object.entries(params).filter(([, v]) => v != null))}`); }
  decision(d, o) { return this.post('/v1/decisions', d, o); }
  learning(l, o) { return this.post('/v1/learnings', l, o); }
  remember(m, o) { return this.post('/v1/memory', m, o); }
}
