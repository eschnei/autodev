#!/usr/bin/env node
// autoDev — one tested Linear helper. Replaces ad-hoc curl+jq everywhere.
// Client-agnostic: reads .autodev/deployment.json at runtime (no placeholders).
//
// Token resolution (in order): $LINEAR_API_TOKEN, then
//   ~/.config/autodev/<client_name>.linear.token   (kept off git/chat)
// Config resolution: $AUTODEV_CONFIG, else nearest .autodev/deployment.json walking up from cwd.
//
// Usage:
//   node linear.mjs whoami
//   node linear.mjs doctor                       # validate token + team + every config status id (live)
//   node linear.mjs state-id <stageKey>          # e.g. ai_qa -> the live state UUID
//   node linear.mjs move <ISSUE> <stageKey>      # ISSUE = identifier (ADX-4) or UUID
//   node linear.mjs comment <ISSUE> "<markdown>"
//   node linear.mjs create-issue --title T [--desc D] [--stage key] [--labels a,b] [--project ID] [--milestone ID]
//   node linear.mjs create-project --name N [--desc D]
//   node linear.mjs create-milestone --project ID --name N
//
// Exit 0 on success (prints the useful id/identifier); non-zero with a clear error otherwise.

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';

const API = 'https://api.linear.app/graphql';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function die(msg) { console.error(`linear.mjs: ${msg}`); process.exit(1); }

function findConfig() {
  if (process.env.AUTODEV_CONFIG) return process.env.AUTODEV_CONFIG;
  let dir = process.cwd();
  for (let i = 0; i < 12; i++) {
    const p = join(dir, '.autodev', 'deployment.json');
    try { readFileSync(p); return p; } catch { /* keep walking */ }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  die('could not find .autodev/deployment.json (set $AUTODEV_CONFIG)');
}

function loadConfig() {
  const path = findConfig();
  try { return JSON.parse(readFileSync(path, 'utf8')); }
  catch (e) { die(`bad config at ${path}: ${e.message}`); }
}

function loadToken(cfg) {
  if (process.env.LINEAR_API_TOKEN) return process.env.LINEAR_API_TOKEN.trim();
  const client = cfg.client_name || 'client';
  const file = join(homedir(), '.config', 'autodev', `${client}.linear.token`);
  try { return readFileSync(file, 'utf8').trim(); }
  catch { die(`no token: set $LINEAR_API_TOKEN or create ${file}`); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// GraphQL with retry/backoff on network errors, 5xx, and 429.
async function gql(token, query, variables = {}, attempt = 0) {
  let res;
  try {
    res = await fetch(API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: token },
      body: JSON.stringify({ query, variables }),
    });
  } catch (e) {
    if (attempt < 3) { await sleep(500 * 2 ** attempt); return gql(token, query, variables, attempt + 1); }
    die(`network error after retries: ${e.message}`);
  }
  if ((res.status >= 500 || res.status === 429) && attempt < 3) {
    await sleep(800 * 2 ** attempt); return gql(token, query, variables, attempt + 1);
  }
  const json = await res.json().catch(() => ({}));
  if (json.errors) die(`API: ${json.errors.map((e) => e.message).join('; ')}`);
  if (!res.ok) die(`HTTP ${res.status}`);
  return json.data;
}

// Resolve an issue arg (identifier like ADX-4, or a UUID) to its UUID.
async function issueId(token, ref) {
  if (UUID_RE.test(ref)) return ref;
  const d = await gql(token, 'query($id:String!){issue(id:$id){id}}', { id: ref });
  if (!d.issue) die(`issue not found: ${ref}`);
  return d.issue.id;
}

function stateId(cfg, key) {
  const s = cfg.tracker?.statuses?.[key];
  if (!s?.id || s.id === 'FILL_AT_SETUP') die(`no live state id for stage "${key}" in config`);
  return s.id;
}

async function labelIds(token, cfg, names) {
  if (!names?.length) return [];
  const d = await gql(token, 'query($t:String!){team(id:$t){labels(first:200){nodes{id name}}}}', { t: cfg.tracker.team_id });
  const map = new Map(d.team.labels.nodes.map((n) => [n.name, n.id]));
  return names.map((n) => map.get(n) || die(`label not found: ${n}`));
}

// ---- subcommands -----------------------------------------------------------
function flags(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[++i];
  return o;
}

const cmds = {
  async whoami(token) {
    const d = await gql(token, '{viewer{name email}}');
    console.log(`${d.viewer.name} <${d.viewer.email}>`);
  },
  async doctor(token, cfg) {
    const d = await gql(token, 'query($t:String!){viewer{email} team(id:$t){name states(first:50){nodes{id}}}}', { t: cfg.tracker.team_id });
    if (!d.team) die(`team_id ${cfg.tracker.team_id} not found for ${d.viewer.email}`);
    const live = new Set(d.team.states.nodes.map((n) => n.id));
    const bad = Object.entries(cfg.tracker.statuses || {})
      .filter(([, s]) => s.id && s.id !== 'FILL_AT_SETUP' && !live.has(s.id))
      .map(([k]) => k);
    if (bad.length) die(`config status ids not present on team "${d.team.name}": ${bad.join(', ')}`);
    console.log(`ok: ${d.viewer.email} · team "${d.team.name}" · ${Object.keys(cfg.tracker.statuses || {}).length} statuses verified`);
  },
  async 'state-id'(token, cfg, a) { console.log(stateId(cfg, a[0])); },
  async move(token, cfg, a) {
    const id = await issueId(token, a[0]);
    const d = await gql(token, 'mutation($id:String!,$i:IssueUpdateInput!){issueUpdate(id:$id,input:$i){success issue{identifier state{name}}}}',
      { id, i: { stateId: stateId(cfg, a[1]) } });
    if (!d.issueUpdate.success) die('move failed');
    console.log(`${d.issueUpdate.issue.identifier} -> ${d.issueUpdate.issue.state.name}`);
  },
  async comment(token, cfg, a) {
    const id = await issueId(token, a[0]);
    const d = await gql(token, 'mutation($i:CommentCreateInput!){commentCreate(input:$i){success}}', { i: { issueId: id, body: a[1] } });
    if (!d.commentCreate.success) die('comment failed');
    console.log('ok');
  },
  async 'create-issue'(token, cfg, a) {
    const f = flags(a);
    if (!f.title) die('create-issue needs --title');
    const input = { teamId: cfg.tracker.team_id, title: f.title };
    if (f.desc) input.description = f.desc;
    if (f.stage) input.stateId = stateId(cfg, f.stage);
    if (f.project) input.projectId = f.project;
    if (f.milestone) input.projectMilestoneId = f.milestone;
    if (f.labels) input.labelIds = await labelIds(token, cfg, f.labels.split(','));
    const d = await gql(token, 'mutation($i:IssueCreateInput!){issueCreate(input:$i){success issue{id identifier url}}}', { i: input });
    if (!d.issueCreate.success) die('create-issue failed');
    console.log(`${d.issueCreate.issue.identifier}\t${d.issueCreate.issue.id}\t${d.issueCreate.issue.url}`);
  },
  async 'create-project'(token, cfg, a) {
    const f = flags(a);
    if (!f.name) die('create-project needs --name');
    const input = { name: f.name, teamIds: [cfg.tracker.team_id] };
    if (f.desc) input.description = f.desc;
    const d = await gql(token, 'mutation($i:ProjectCreateInput!){projectCreate(input:$i){success project{id url}}}', { i: input });
    if (!d.projectCreate.success) die('create-project failed');
    console.log(`${d.projectCreate.project.id}\t${d.projectCreate.project.url}`);
  },
  async 'create-milestone'(token, cfg, a) {
    const f = flags(a);
    if (!f.project || !f.name) die('create-milestone needs --project and --name');
    const d = await gql(token, 'mutation($i:ProjectMilestoneCreateInput!){projectMilestoneCreate(input:$i){success projectMilestone{id name}}}',
      { i: { projectId: f.project, name: f.name } });
    if (!d.projectMilestoneCreate.success) die('create-milestone failed');
    console.log(`${d.projectMilestoneCreate.projectMilestone.id}\t${d.projectMilestoneCreate.projectMilestone.name}`);
  },
};

const [cmd, ...rest] = process.argv.slice(2);
if (!cmd || !cmds[cmd]) die(`unknown command "${cmd || ''}". See header for usage.`);
const cfg = loadConfig();
const token = loadToken(cfg);
await cmds[cmd](token, cfg, rest);
