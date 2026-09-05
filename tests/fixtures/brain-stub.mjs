#!/usr/bin/env node
// A stand-in Brain for autoDev's tests: speaks the /v1 contract autoDev depends on
// (discovery, health, projects, repositories, requirements, context, handoffs,
// decisions, search), keeps state in memory, and appends every request as one JSON
// line to $BRAIN_STUB_LOG so a test can assert exactly what autoDev sent. Not Brain —
// autoDev's tests must stay hermetic and independent of the Brain checkout.
//   BRAIN_STUB_API   the api version to advertise (default 1.0.0)
//   BRAIN_STUB_TOKEN the bearer token that is accepted (default "stub-token")
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';

const API = process.env.BRAIN_STUB_API || '1.0.0';
const TOKEN = process.env.BRAIN_STUB_TOKEN || 'stub-token';
const LOG = process.env.BRAIN_STUB_LOG;
let n = 0;
const id = (p) => `${p}_01STUB${String(++n).padStart(20, '0')}`;
const state = { projects: [], repos: [], requirements: [], handoffs: [], decisions: [], memories: [] };
state.memories.push({ id: id('mem'), revision: 2, scope: { type: 'project', id: 'stub' }, state: 'canonical', type: 'rule', content: 'The local tracker is the workflow state machine', provenance: [{ type: 'human_decision' }] });
state.memories.push({ id: id('mem'), revision: 1, scope: { type: 'project', id: 'stub' }, state: 'verified', type: 'failure', content: 'The test DB pool leaks under the integration suite', provenance: [{ type: 'test' }] });
const idem = new Map();

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const chunks = []; for await (const c of req) chunks.push(c);
  const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {};
  const send = (status, obj) => { res.writeHead(status, { 'Content-Type': 'application/json', 'X-Brain-Api': API }); res.end(JSON.stringify(obj)); };
  if (LOG) appendFileSync(LOG, JSON.stringify({ method: req.method, path: url.pathname + url.search, auth: req.headers.authorization || null, client: req.headers['x-brain-client'] || null, idem: req.headers['idempotency-key'] || null, body }) + '\n');
  const p = url.pathname;
  if (req.method === 'GET' && p === '/v1') return send(200, { name: 'brain-stub', version: '0.0.0', api: API, capabilities: ['scoped-memory', 'context', 'handoffs', 'decisions', 'idempotency'], user_id: 'usr_stub' });
  if (req.method === 'GET' && p === '/v1/health') return send(200, { ok: true, uptime_s: 1 });
  if (req.headers.authorization !== `Bearer ${TOKEN}`) return send(401, { error: 'unauthorized', message: 'bad token' });
  const key = req.headers['idempotency-key'];
  if (key && idem.has(key)) return send(200, { ...idem.get(key), replayed: true });
  const done = (status, obj) => { if (key) idem.set(key, obj); return send(status, obj); };
  let m;
  if (req.method === 'GET' && p === '/v1/projects') return send(200, state.projects);
  if (req.method === 'POST' && p === '/v1/projects') { const pr = { id: id('prj'), ...body }; state.projects.push(pr); return done(201, pr); }
  if ((m = /^\/v1\/projects\/([^/]+)$/.exec(p)) && req.method === 'GET') { const k = decodeURIComponent(m[1]); const pr = state.projects.find((x) => x.id === k || x.key === k); return pr ? send(200, pr) : send(404, { error: 'not_found', message: 'project not found' }); }
  if ((m = /^\/v1\/projects\/([^/]+)\/repositories$/.exec(p)) && req.method === 'POST') { const r = { id: id('repo'), project_id: m[1], ...body }; state.repos.push(r); return done(201, r); }
  if ((m = /^\/v1\/projects\/([^/]+)\/requirements$/.exec(p)) && req.method === 'GET') return send(200, state.requirements.filter((r) => r.project_id === m[1]));
  if ((m = /^\/v1\/projects\/([^/]+)\/requirements$/.exec(p)) && req.method === 'POST') { const r = { id: id('req'), project_id: m[1], ...body }; state.requirements.push(r); return done(201, r); }
  if (req.method === 'POST' && p === '/v1/context') {
    const latest = state.handoffs.filter((h) => h.project_id === body.project_id).at(-1) || null;
    return send(201, { id: id('ctx'), api: API, project: { id: body.project_id, name: state.projects.find((x) => x.id === body.project_id)?.name || 'stub' }, scope_chain: [{ type: 'project', id: body.project_id }, { type: 'user', id: 'usr_stub' }], related_projects: [], requirement: body.requirement_id ? state.requirements.find((r) => r.id === body.requirement_id) || null : null, task: null, handoff: latest, memories: state.memories, omitted: 0, budget: body.budget || 40 });
  }
  if (req.method === 'POST' && p === '/v1/handoffs') { const h = { id: id('hnd'), created_at: new Date().toISOString(), ...body }; state.handoffs.push(h); return done(201, h); }
  if (req.method === 'GET' && p === '/v1/handoffs/latest') { const h = state.handoffs.at(-1); return h ? send(200, h) : send(404, { error: 'not_found', message: 'handoff not found' }); }
  if (req.method === 'POST' && p === '/v1/decisions') { const d = { id: id('mem'), type: 'decision', state: 'verified', ...body }; state.decisions.push(d); return done(201, d); }
  if (req.method === 'GET' && p === '/v1/search') { const q = (url.searchParams.get('q') || '').toLowerCase(); return send(200, state.memories.filter((x) => x.content.toLowerCase().includes(q))); }
  return send(404, { error: 'no_route', message: `no route ${req.method} ${p}` });
});
server.listen(Number(process.env.BRAIN_STUB_PORT || 0), '127.0.0.1', () => { process.stdout.write(`${server.address().port}\n`); });
