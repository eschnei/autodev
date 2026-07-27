#!/usr/bin/env node
// autoDev — tracker facade. THE entry point for all board operations; the skills call
// this, never a backend directly. `tracker.kind` in .autodev/deployment.json picks the
// driver:
//   linear   → delegates every command to linear.mjs (the Linear driver, unchanged)
//   shortcut → delegates every command to shortcut.mjs (Shortcut REST v3; cli intake only)
//   local    → git-native board: one JSON file per issue under .autodev/board/. No API,
//              no token, no rate limits; history lives inside each file. Optional
//              best-effort Linear mirroring via tracker.mirror.linear + `flush-mirror`.
//
// Command surface (superset of linear.mjs):
//   move <ISSUE> <stageKey> [--note "why"]      comment <ISSUE> "<markdown>"
//   show <ISSUE>                                 list-comments <ISSUE>
//   create-issue --title T [--desc D] [--stage key] [--labels a,b] [--project P] [--milestone M]
//   update-issue <ISSUE> [--title T] [--desc D] [--stage key] [--labels a,b]
//   relate <ISSUE> <RELATED> [--type blocks|related|duplicate]
//   attach <ISSUE> <url> [--title T]             create-project --name N [--desc D]
//   create-milestone --project P --name N        list [--stage key]
//   board [--html <path>]                        state-id <stageKey>
//   whoami | doctor                              flush-mirror
// Exit 0 on success (prints the useful id); non-zero with a clear error otherwise.

import { readFileSync, writeFileSync, renameSync, readdirSync, existsSync, mkdirSync, appendFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { loadConfig } from './lib/config.mjs';

function die(msg) { console.error(`tracker.mjs: ${msg}`); process.exit(1); }

const { cfg, configPath: CONFIG_PATH } = loadConfig();
if (!cfg) die('no .autodev/deployment.json found (set $AUTODEV_CONFIG or run inside the repo)');
const ROOT = dirname(dirname(CONFIG_PATH));
const BOARD = join(ROOT, '.autodev', 'board');
const KIND = cfg.tracker?.kind || 'linear';
const MIRROR = KIND === 'local' && cfg.tracker?.mirror?.linear === true;

// ---- API-driver delegation (linear.mjs / shortcut.mjs) -------------------------
function delegateTo(driver, argv) {
  const r = spawnSync('node', [join(dirname(new URL(import.meta.url).pathname), driver), ...argv], { stdio: 'inherit' });
  process.exit(r.status ?? 1);
}

// ---- local store -------------------------------------------------------------
const now = () => new Date().toISOString();
function ensureBoard() { mkdirSync(BOARD, { recursive: true }); }
function issuePath(id) { return join(BOARD, `${id}.json`); }
function writeAtomic(path, obj) {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n');
  renameSync(tmp, path);
}
function loadIssue(ref) {
  // accept exact id (AD-4), case-insensitive, or unique title substring
  ensureBoard();
  const files = readdirSync(BOARD).filter((f) => f.endsWith('.json') && !f.startsWith('_'));
  const exact = files.find((f) => f.replace('.json', '').toLowerCase() === ref.toLowerCase());
  if (exact) return JSON.parse(readFileSync(join(BOARD, exact), 'utf8'));
  const all = files.map((f) => JSON.parse(readFileSync(join(BOARD, f), 'utf8')));
  const hits = all.filter((i) => i.title.toLowerCase().includes(ref.toLowerCase()));
  if (hits.length === 1) return hits[0];
  die(hits.length ? `ambiguous ref "${ref}" (${hits.map((h) => h.id).join(', ')})` : `not found: ${ref}`);
}
function saveIssue(issue) { issue.updated_at = now(); writeAtomic(issuePath(issue.id), issue); }
function nextId() {
  ensureBoard();
  const cPath = join(BOARD, '.counter');
  const n = existsSync(cPath) ? parseInt(readFileSync(cPath, 'utf8'), 10) + 1 : 1;
  writeFileSync(cPath, String(n));
  return `AD-${n}`;
}
function stageName(key) {
  const s = cfg.tracker?.statuses?.[key];
  if (!s) die(`unknown stage key "${key}" (see tracker.statuses in deployment.json)`);
  return s.name || key;
}
function queueMirror(op) { if (MIRROR) { ensureBoard(); appendFileSync(join(BOARD, '.mirror-queue.jsonl'), JSON.stringify({ at: now(), ...op }) + '\n'); } }
function flags(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[++i];
  return o;
}

const local = {
  'state-id'(a) { console.log(stageName(a[0])); },
  whoami() { console.log(`local board (${BOARD})`); },
  doctor() {
    ensureBoard();
    const n = readdirSync(BOARD).filter((f) => f.endsWith('.json') && !f.startsWith('_')).length;
    const q = existsSync(join(BOARD, '.mirror-queue.jsonl'))
      ? readFileSync(join(BOARD, '.mirror-queue.jsonl'), 'utf8').trim().split('\n').filter(Boolean).length : 0;
    console.log(`ok: local board · ${n} issues · mirror ${MIRROR ? `ON (${q} queued)` : 'off'} · ${BOARD}`);
  },
  'create-issue'(a) {
    const f = flags(a);
    if (!f.title) die('create-issue needs --title');
    const issue = {
      id: nextId(), title: f.title, description: f.desc || '',
      stage: f.stage || 'new_request', labels: f.labels ? f.labels.split(',') : [],
      project: f.project || null, milestone: f.milestone || null,
      relations: [], attachments: [], comments: [],
      history: [{ at: now(), to: f.stage || 'new_request', note: 'created' }],
      linear_id: null, created_at: now(), updated_at: now(),
    };
    saveIssue(issue);
    queueMirror({ op: 'create', id: issue.id });
    console.log(issue.id);
  },
  move(a) {
    const issue = loadIssue(a[0]);
    const from = issue.stage; const to = a[1];
    stageName(to); // validate
    const note = flags(a.slice(2)).note || null;
    issue.stage = to;
    issue.history.push({ at: now(), from, to, note });
    if (note) issue.comments.push({ author: 'autodev', at: now(), body: note });
    saveIssue(issue);
    queueMirror({ op: 'move', id: issue.id, to, note });
    console.log(`${issue.id} -> ${stageName(to)}${note ? '\nnote posted' : ''}`);
  },
  comment(a) {
    const issue = loadIssue(a[0]);
    issue.comments.push({ author: 'autodev', at: now(), body: a[1] });
    saveIssue(issue);
    queueMirror({ op: 'comment', id: issue.id, body: a[1] });
    console.log('ok');
  },
  'update-issue'(a) {
    const issue = loadIssue(a[0]);
    const f = flags(a.slice(1));
    if (f.title) issue.title = f.title;
    if (f.desc) issue.description = f.desc;
    if (f.stage) { stageName(f.stage); issue.history.push({ at: now(), from: issue.stage, to: f.stage, note: 'update-issue' }); issue.stage = f.stage; }
    if (f.labels) issue.labels = f.labels.split(',');
    saveIssue(issue);
    queueMirror({ op: 'update', id: issue.id, ...f });
    console.log(`${issue.id} updated`);
  },
  relate(a) {
    const issue = loadIssue(a[0]); const related = loadIssue(a[1]);
    const type = flags(a.slice(2)).type || 'blocks';
    issue.relations.push({ type, id: related.id });
    saveIssue(issue);
    console.log(`ok: ${issue.id} ${type} ${related.id}`);
  },
  attach(a) {
    const issue = loadIssue(a[0]);
    if (!a[1]) die('attach needs <issue> <url>');
    issue.attachments.push({ url: a[1], title: flags(a.slice(2)).title || a[1] });
    saveIssue(issue);
    queueMirror({ op: 'attach', id: issue.id, url: a[1] });
    console.log('ok');
  },
  show(a) {
    const i = loadIssue(a[0]);
    console.log(`${i.id}  ${i.title}\nstage: ${stageName(i.stage)} · labels: ${i.labels.join(', ') || '—'} · project: ${i.project || '—'} · milestone: ${i.milestone || '—'}\n\n${i.description || '(no description)'}`);
    if (i.relations.length) console.log(`\nrelations: ${i.relations.map((r) => `${r.type} ${r.id}`).join(' · ')}`);
    if (i.attachments.length) console.log(`attachments: ${i.attachments.map((x) => x.url).join(' · ')}`);
  },
  'list-comments'(a) {
    const i = loadIssue(a[0]);
    if (!i.comments.length) { console.log('(no comments)'); return; }
    for (const c of i.comments) console.log(`— ${c.author} · ${c.at}\n${c.body}\n`);
  },
  list(a) {
    ensureBoard();
    const f = flags(a);
    const all = readdirSync(BOARD).filter((x) => x.endsWith('.json') && !x.startsWith('_'))
      .map((x) => JSON.parse(readFileSync(join(BOARD, x), 'utf8')));
    const rows = f.stage ? all.filter((i) => i.stage === f.stage) : all;
    if (!rows.length) { console.log('(none)'); return; }
    for (const i of rows) console.log(`${i.id}\t${i.stage}\t${i.title}`);
  },
  board(a) {
    ensureBoard();
    const all = readdirSync(BOARD).filter((x) => x.endsWith('.json') && !x.startsWith('_'))
      .map((x) => JSON.parse(readFileSync(join(BOARD, x), 'utf8')));
    const order = Object.keys(cfg.tracker?.statuses || {});
    for (const key of order) {
      const rows = all.filter((i) => i.stage === key);
      if (!rows.length) continue;
      console.log(`\n■ ${stageName(key)} (${rows.length})`);
      for (const i of rows) console.log(`  ${i.id}  ${i.title}`);
    }
    const htmlPath = flags(a).html || join(ROOT, '.autodev', 'board.html');
    const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    const cols = order.map((key) => {
      const rows = all.filter((i) => i.stage === key);
      const cards = rows.map((i) => {
        const links = (i.attachments || [])
          .map((a) => `<a href="${esc(a.url)}" target="_blank">${esc(a.title || 'link')}</a>`).join(' · ');
        return `<div class="card"><b>${esc(i.id)}</b> ${esc(i.title)}<div class="meta">${esc(i.labels.join(' '))}${links ? ` · ${links}` : ''}</div></div>`;
      }).join('');
      return `<div class="col"><h3>${esc(stageName(key))} <span>${rows.length}</span></h3>${cards}</div>`;
    }).join('');
    writeFileSync(htmlPath, `<!doctype html><meta charset="utf-8"><title>autoDev board — ${esc(cfg.client_name || '')}</title>
<style>body{font:14px system-ui;margin:16px;background:#f4f5f8}h1{font-size:18px}.wrap{display:flex;gap:12px;align-items:flex-start;overflow-x:auto}
.col{background:#e9ebf0;border-radius:8px;padding:10px;min-width:220px}.col h3{font-size:13px;margin:2px 4px 8px}.col h3 span{color:#888;font-weight:400}
.card{background:#fff;border-radius:6px;padding:8px;margin-bottom:8px;box-shadow:0 1px 2px rgba(0,0,0,.08)}.meta{color:#999;font-size:11px;margin-top:4px}</style>
<h1>autoDev — ${esc(cfg.client_name || '')} <small style="color:#999">generated ${now()}</small></h1><div class="wrap">${cols}</div>`);
    console.log(`\nboard written: ${htmlPath}`);
  },
  'create-project'(a) {
    const f = flags(a);
    if (!f.name) die('create-project needs --name');
    ensureBoard();
    const p = join(BOARD, '_projects.json');
    const reg = existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : { projects: [] };
    reg.projects.push({ name: f.name, description: f.desc || '', milestones: [], created_at: now() });
    writeAtomic(p, reg);
    console.log(f.name);
  },
  'create-milestone'(a) {
    const f = flags(a);
    if (!f.project || !f.name) die('create-milestone needs --project and --name');
    const p = join(BOARD, '_projects.json');
    const reg = existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : { projects: [] };
    const proj = reg.projects.find((x) => x.name === f.project) || (reg.projects.push({ name: f.project, milestones: [] }), reg.projects.at(-1));
    proj.milestones.push({ name: f.name, created_at: now() });
    writeAtomic(p, reg);
    console.log(f.name);
  },
  'flush-mirror'() {
    // Best-effort one-way mirror to Linear: coalesce queued ops per issue, then replay
    // via linear.mjs (which has retry/backoff). Failures keep the queue for next flush.
    if (!MIRROR) { console.log('mirror off (tracker.mirror.linear != true)'); return; }
    const qPath = join(BOARD, '.mirror-queue.jsonl');
    if (!existsSync(qPath)) { console.log('queue empty'); return; }
    const ops = readFileSync(qPath, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
    if (!ops.length) { console.log('queue empty'); return; }
    const linear = (args) => spawnSync('node', [join(dirname(new URL(import.meta.url).pathname), 'linear.mjs'), ...args], { encoding: 'utf8' });
    const failed = [];
    const byIssue = new Map();
    for (const op of ops) { if (!byIssue.has(op.id)) byIssue.set(op.id, []); byIssue.get(op.id).push(op); }
    for (const [id, issueOps] of byIssue) {
      const issue = JSON.parse(readFileSync(issuePath(id), 'utf8'));
      try {
        if (!issue.linear_id) {
          const r = linear(['create-issue', '--title', `[${issue.id}] ${issue.title}`, '--desc', issue.description || '', '--stage', issue.stage]);
          if (r.status !== 0) throw new Error(r.stderr || 'create failed');
          issue.linear_id = (r.stdout || '').trim().split('\n').pop();
          saveIssue(issue);
        }
        // coalesce: final stage once; every comment/attach in order
        const finalMove = [...issueOps].reverse().find((o) => o.op === 'move' || o.op === 'update');
        if (finalMove && (finalMove.to || finalMove.stage)) {
          const r = linear(['move', issue.linear_id, finalMove.to || finalMove.stage]);
          if (r.status !== 0) throw new Error(r.stderr || 'move failed');
        }
        for (const o of issueOps) {
          if (o.op === 'comment' || (o.op === 'move' && o.note)) {
            const r = linear(['comment', issue.linear_id, o.body || o.note]);
            if (r.status !== 0) throw new Error(r.stderr || 'comment failed');
          }
          if (o.op === 'attach') {
            const r = linear(['attach', issue.linear_id, o.url]);
            if (r.status !== 0) throw new Error(r.stderr || 'attach failed');
          }
        }
      } catch (e) {
        failed.push(...issueOps);
        console.error(`mirror: ${id} deferred (${String(e.message).slice(0, 120)})`);
      }
    }
    writeFileSync(qPath, failed.length ? failed.map((o) => JSON.stringify(o)).join('\n') + '\n' : '');
    console.log(`mirror: ${byIssue.size} issues processed · ${failed.length} ops deferred`);
  },
};

const [cmd, ...args] = process.argv.slice(2);
if (!cmd) die('usage: tracker.mjs <command> … (see header)');

if (KIND === 'linear' || KIND === 'shortcut') {
  if (cmd === 'flush-mirror') { console.log(`tracker.kind=${KIND} — nothing to mirror`); process.exit(0); }
  if (cmd === 'list' || cmd === 'board') die(`'${cmd}' is local-driver only for now — use the ${KIND === 'linear' ? 'Linear' : 'Shortcut'} UI`);
  delegateTo(KIND === 'linear' ? 'linear.mjs' : 'shortcut.mjs', [cmd, ...args]);
} else if (KIND === 'local') {
  const fn = local[cmd];
  if (!fn) die(`unknown command "${cmd}"`);
  try { fn(args); } catch (e) { die(e.message); }
} else {
  die(`unknown tracker.kind "${KIND}" (local | linear | shortcut)`);
}
