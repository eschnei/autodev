#!/usr/bin/env node
// autoDev — the Shortcut driver (sibling of linear.mjs). REST API v3
// (https://developer.shortcut.com/api/rest/v3), auth header `Shortcut-Token`,
// 200 req/min rate limit (429 on excess — retried with backoff below).
//
// Mapping (autoDev vocabulary → Shortcut):
//   story → Story · epic (parallel lane) → Epic (story.epic_id) ·
//   feature grouping ("project") → Milestone (epic.milestone_id) ·
//   dependency → Story Link (verb: blocks | duplicates | "relates to") ·
//   stage → workflow state id from tracker.shortcut.statuses (same stage KEYS as
//   linear) · attach → story.external_links (PUT) · labels → inline {name} objects
//   (Shortcut auto-creates them — no lookup step needed).
// Tradeoffs: stories can't reference Milestones directly, so create-issue --project
//   is recorded as a label `feature:<id>` (the lane Epic carries the real
//   milestone_id); comment-driven intake stays Linear-only (Shortcut mode is cli).
//
// Token resolution (in order): $<tracker.shortcut.api_token_env> (default
//   $SHORTCUT_API_TOKEN), then ~/.config/autodev/<client_name>.shortcut.token
// Config resolution: $AUTODEV_CONFIG, else nearest .autodev/deployment.json walking up.
//
// Usage mirrors linear.mjs:
//   node shortcut.mjs whoami | doctor | state-id <stageKey>
//   node shortcut.mjs move <STORY> <stageKey> [--note "why"]
//   node shortcut.mjs comment <STORY> "<markdown>"
//   node shortcut.mjs show <STORY> · list-comments <STORY>
//   node shortcut.mjs create-issue --title T [--desc D] [--stage key] [--labels a,b] [--project P] [--milestone EPIC_ID]
//   node shortcut.mjs update-issue <STORY> [--title T] [--desc D] [--stage key] [--labels a,b]
//   node shortcut.mjs relate <STORY> <RELATED> [--type blocks|related|duplicate]
//   node shortcut.mjs attach <STORY> <url> [--title T]
//   node shortcut.mjs create-project --name N [--desc D]        # Shortcut Milestone
//   node shortcut.mjs create-milestone --project MILESTONE_ID --name N   # Shortcut Epic
//
// Exit 0 on success (prints the useful id); non-zero with a clear error otherwise.

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { loadConfig as loadSharedConfig } from './lib/config.mjs';

const API = 'https://api.app.shortcut.com/api/v3';

function die(msg) { console.error(`shortcut.mjs: ${msg}`); process.exit(1); }

function loadConfig() {
  const { cfg } = loadSharedConfig();
  if (!cfg) die('could not find .autodev/deployment.json (set $AUTODEV_CONFIG)');
  return cfg;
}

function loadToken(cfg) {
  const envName = cfg.tracker?.shortcut?.api_token_env || 'SHORTCUT_API_TOKEN';
  if (process.env[envName]) return process.env[envName].trim();
  const client = cfg.client_name || 'client';
  const file = cfg.tracker?.shortcut?.api_token_file || join(homedir(), '.config', 'autodev', `${client}.shortcut.token`);
  try { return readFileSync(file, 'utf8').trim(); }
  catch { die(`no token: set $${envName} or create ${file}`); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// REST with retry/backoff on network errors, 5xx, and 429 (200 req/min limit).
async function api(token, method, path, body, attempt = 0) {
  let res;
  try {
    res = await fetch(`${API}${path}`, {
      method,
      headers: { 'Content-Type': 'application/json', 'Shortcut-Token': token },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (e) {
    if (attempt < 3) { await sleep(500 * 2 ** attempt); return api(token, method, path, body, attempt + 1); }
    die(`network error after retries: ${e.message}`);
  }
  if ((res.status >= 500 || res.status === 429) && attempt < 3) {
    await sleep(800 * 2 ** attempt); return api(token, method, path, body, attempt + 1);
  }
  const json = await res.json().catch(() => ({}));
  if (!res.ok) die(`HTTP ${res.status}: ${json.message || JSON.stringify(json).slice(0, 200)}`);
  return json;
}

// Story ids are public integers; accept "123" or Shortcut's branch-style "sc-123".
function storyId(ref) {
  const m = String(ref).match(/^(?:sc-)?(\d+)$/i);
  if (!m) die(`not a Shortcut story id: "${ref}" (use the numeric public id, e.g. 123 or sc-123)`);
  return Number(m[1]);
}

function stateId(cfg, key) {
  const s = cfg.tracker?.shortcut?.statuses?.[key];
  if (!s?.id || String(s.id).startsWith('FILL')) die(`no workflow state id for stage "${key}" in tracker.shortcut.statuses`);
  return Number(s.id);
}

const labelObjs = (csv) => csv.split(',').map((n) => ({ name: n.trim() })).filter((l) => l.name);

function flags(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[++i];
  return o;
}

// ---- subcommands -----------------------------------------------------------
const cmds = {
  async whoami(token) {
    const m = await api(token, 'GET', '/member');
    console.log(`${m.name || m.mention_name} (@${m.mention_name}) · ${m.workspace2?.url_slug || ''}`);
  },
  async doctor(token, cfg) {
    const m = await api(token, 'GET', '/member');
    const workflows = await api(token, 'GET', '/workflows');
    const wfId = cfg.tracker?.shortcut?.workflow_id;
    const wf = String(wfId || '').startsWith('FILL') || !wfId
      ? null : workflows.find((w) => String(w.id) === String(wfId));
    if (wfId && !String(wfId).startsWith('FILL') && !wf) die(`workflow_id ${wfId} not found (have: ${workflows.map((w) => `${w.id} "${w.name}"`).join(', ')})`);
    const live = new Set((wf ? wf.states : workflows.flatMap((w) => w.states)).map((s) => String(s.id)));
    const bad = Object.entries(cfg.tracker?.shortcut?.statuses || {})
      .filter(([, s]) => s.id && !String(s.id).startsWith('FILL') && !live.has(String(s.id)))
      .map(([k]) => k);
    if (bad.length) die(`config state ids not present ${wf ? `in workflow "${wf.name}"` : 'in any workflow'}: ${bad.join(', ')}`);
    const n = Object.keys(cfg.tracker?.shortcut?.statuses || {}).length;
    console.log(`ok: @${m.mention_name}${wf ? ` · workflow "${wf.name}"` : ''} · ${n} statuses verified`);
  },
  async 'state-id'(token, cfg, a) { console.log(stateId(cfg, a[0])); },
  async move(token, cfg, a) {
    const id = storyId(a[0]);
    const s = await api(token, 'PUT', `/stories/${id}`, { workflow_state_id: stateId(cfg, a[1]) });
    console.log(`sc-${s.id} -> ${a[1]}`);
    // --note posts the reason with the move — no silent status changes (principle 9)
    const note = flags(a.slice(2)).note;
    if (note) {
      await api(token, 'POST', `/stories/${id}/comments`, { text: note });
      console.log('note posted');
    }
  },
  async comment(token, cfg, a) {
    await api(token, 'POST', `/stories/${storyId(a[0])}/comments`, { text: a[1] });
    console.log('ok');
  },
  async 'update-issue'(token, cfg, a) {
    const id = storyId(a[0]);
    const f = flags(a.slice(1));
    const input = {};
    if (f.title) input.name = f.title;
    if (f.desc) input.description = f.desc;
    if (f.stage) input.workflow_state_id = stateId(cfg, f.stage);
    if (f.labels) input.labels = labelObjs(f.labels);
    if (Object.keys(input).length === 0) die('update-issue: use --title/--desc/--stage/--labels');
    const s = await api(token, 'PUT', `/stories/${id}`, input);
    console.log(`sc-${s.id} updated`);
  },
  async relate(token, cfg, a) {   // relate <story> <related> [--type blocks|related|duplicate]
    const verb = { blocks: 'blocks', related: 'relates to', duplicate: 'duplicates' }[flags(a.slice(2)).type || 'blocks'];
    if (!verb) die('relate --type must be blocks|related|duplicate');
    await api(token, 'POST', '/story-links', { subject_id: storyId(a[0]), verb, object_id: storyId(a[1]) });
    console.log(`ok: sc-${storyId(a[0])} ${verb} sc-${storyId(a[1])}`);
  },
  async show(token, cfg, a) {
    const s = await api(token, 'GET', `/stories/${storyId(a[0])}`);
    const stage = Object.entries(cfg.tracker?.shortcut?.statuses || {})
      .find(([, v]) => String(v.id) === String(s.workflow_state_id))?.[0] || s.workflow_state_id;
    console.log(`sc-${s.id}  ${s.name}\nstate: ${stage} · labels: ${(s.labels || []).map((l) => l.name).join(', ') || '—'} · epic: ${s.epic_id || '—'}\n${s.app_url}\n\n${s.description || '(no description)'}`);
    if (s.external_links?.length) console.log(`\nattachments: ${s.external_links.join(' · ')}`);
  },
  async 'list-comments'(token, cfg, a) {
    const comments = await api(token, 'GET', `/stories/${storyId(a[0])}/comments`);
    if (!comments.length) { console.log('(no comments)'); return; }
    for (const c of comments) console.log(`— member ${c.author_id || '?'} · ${c.created_at}\n${c.text}\n`);
  },
  async attach(token, cfg, a) {   // append to story.external_links (Shortcut has no titled URL attachments)
    const id = storyId(a[0]);
    if (!a[1]) die('attach needs <issue> <url>');
    const s = await api(token, 'GET', `/stories/${id}`);
    const links = [...new Set([...(s.external_links || []), a[1]])];
    await api(token, 'PUT', `/stories/${id}`, { external_links: links });
    console.log(`ok: attached ${a[1]}`);
  },
  async 'create-issue'(token, cfg, a) {
    const f = flags(a);
    if (!f.title) die('create-issue needs --title');
    const input = { name: f.title, story_type: 'feature' };
    if (f.desc) input.description = f.desc;
    if (f.stage) input.workflow_state_id = stateId(cfg, f.stage);
    if (f.milestone) input.epic_id = Number(f.milestone);   // autoDev "milestone" (lane) = Shortcut Epic
    if (f.labels) input.labels = labelObjs(f.labels);
    if (f.project) input.labels = [...(input.labels || []), { name: `feature:${f.project}` }]; // stories can't point at Milestones — see header
    if (cfg.tracker?.shortcut?.group_id && !String(cfg.tracker.shortcut.group_id).startsWith('FILL')) input.group_id = cfg.tracker.shortcut.group_id;
    const s = await api(token, 'POST', '/stories', input);
    console.log(`sc-${s.id}\t${s.id}\t${s.app_url}`);
  },
  async 'create-project'(token, cfg, a) {   // autoDev "project" (feature grouping) = Shortcut Milestone
    const f = flags(a);
    if (!f.name) die('create-project needs --name');
    const input = { name: f.name };
    if (f.desc) input.description = f.desc;
    const m = await api(token, 'POST', '/milestones', input);
    console.log(`${m.id}\t${m.app_url || ''}`);
  },
  async 'create-milestone'(token, cfg, a) {  // autoDev "milestone" (epic lane) = Shortcut Epic
    const f = flags(a);
    if (!f.project || !f.name) die('create-milestone needs --project and --name');
    const input = { name: f.name, milestone_id: Number(f.project) };
    if (cfg.tracker?.shortcut?.group_id && !String(cfg.tracker.shortcut.group_id).startsWith('FILL')) input.group_id = cfg.tracker.shortcut.group_id;
    const e = await api(token, 'POST', '/epics', input);
    console.log(`${e.id}\t${e.name}`);
  },
};

const [cmd, ...rest] = process.argv.slice(2);
if (!cmd || !cmds[cmd]) die(`unknown command "${cmd || ''}". See header for usage.`);
const cfg = loadConfig();
const token = loadToken(cfg);
await cmds[cmd](token, cfg, rest);
