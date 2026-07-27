#!/usr/bin/env node
// autoDev — periodic operator DIGEST (B4). Cheap, no Claude. Self-gating on
// reporting.cadence. Call it at the end of each heartbeat tick (devloop-tick.sh)
// or from its own timer; it only emits when the cadence window has elapsed.
//
// Config (deployment.json → reporting):
//   cadence:  "off" | "hourly" | "<N>m" | "<N>h"   (default off)
//   destination: "slack" | "linear" | "log"        (default log)
//   slack_webhook: "<url>"   (or $SLACK_WEBHOOK)    — for destination slack
//   linear_issue:  "<id>"    — for destination linear (comment on this issue)
//
// Usage: node report.mjs [--force]    (--force ignores the cadence window)

import { readFileSync, appendFileSync, mkdirSync, statSync, writeFileSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { execSync } from 'node:child_process';
import { loadConfig } from './lib/config.mjs';

const API = 'https://api.linear.app/graphql';
const force = process.argv.includes('--force');

const { cfg, configPath: CONFIG_PATH } = loadConfig();
if (!cfg) { console.error('report.mjs: no .autodev/deployment.json'); process.exit(1); }
const rep = cfg.reporting || {};

// cadence → seconds
function cadenceSeconds(c) {
  if (!c || c === 'off') return 0;
  if (c === 'hourly') return 3600;
  const m = String(c).match(/^(\d+)\s*([mh])$/);
  if (!m) return 0;
  return Number(m[1]) * (m[2] === 'h' ? 3600 : 60);
}
const win = cadenceSeconds(rep.cadence);
if (win === 0) process.exit(0); // reporting off

const RUN_HOME = (cfg.runner?.home_dir || join(dirname(dirname(CONFIG_PATH)), '.autodev')).replace(/^~/, homedir());
const marker = join(dirname(CONFIG_PATH), '.last_report');
const now = Math.floor(Date.now() / 1000);
let last = 0; try { last = Math.floor(statSync(marker).mtimeMs / 1000); } catch {}
if (!force && last && now - last < win) process.exit(0); // not due yet

function loadToken() {
  if (process.env.LINEAR_API_TOKEN) return process.env.LINEAR_API_TOKEN.trim();
  const f = cfg.tracker?.linear?.api_token_file || join(homedir(), '.config', 'autodev', `${cfg.client_name || 'client'}.linear.token`);
  try { return readFileSync(f, 'utf8').trim(); } catch { return null; }
}
const token = loadToken();

async function gql(q, v = {}) {
  const r = await fetch(API, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: token }, body: JSON.stringify({ query: q, variables: v }) });
  return (await r.json()).data;
}

// --- gather snapshot (kind-aware: local board files, or live Linear) ---
const buckets = { inflight: 0, awaiting_human: 0, done: 0, blocked: 0, queued: 0 };
const bucketOf = (name, completed) => {
  if (/Blocked/i.test(name)) return 'blocked';
  if (name.includes('(H)')) return 'awaiting_human';
  if (/AI Development|AI QA/i.test(name)) return 'inflight';
  if (completed) return 'done';
  if (/Ready for AI Dev/i.test(name)) return 'queued';
  return null;
};
if ((cfg.tracker?.kind || 'linear') === 'local') {
  const boardDir = join(dirname(dirname(CONFIG_PATH)), '.autodev', 'board');
  try {
    for (const f of readdirSync(boardDir).filter((x) => x.endsWith('.json') && !x.startsWith('_'))) {
      const i = JSON.parse(readFileSync(join(boardDir, f), 'utf8'));
      const s = cfg.tracker?.statuses?.[i.stage] || {};
      const b = bucketOf(s.name || i.stage, i.stage === 'done');
      if (b) buckets[b]++;
    }
  } catch { /* no board yet — zeros */ }
} else if ((cfg.tracker?.kind || 'linear') !== 'linear') {
  // fail loud, never a silently-zero digest: only local + linear have snapshot paths
  buckets.unsupported = cfg.tracker.kind;
} else if (token && cfg.tracker?.team_id) {
  const d = await gql('query($t:String!){team(id:$t){issues(first:250){nodes{state{name type}}}}}', { t: cfg.tracker.team_id });
  for (const n of d?.team?.issues?.nodes || []) {
    const b = bucketOf(n.state?.name || '', n.state?.type === 'completed');
    if (b) buckets[b]++;
  }
}

// recent commits since last digest, from the target repo
let merged = '(n/a)';
try {
  const repo = cfg.repo?.local_path;
  const sinceArg = last ? `--since=@${last}` : '-n 20';
  merged = execSync(`git -C "${repo}" log ${sinceArg} --oneline 2>/dev/null | wc -l | tr -d ' '`, { encoding: 'utf8' }).trim();
} catch {}

// rate-limit status
let wall = 'running';
try { const until = Number(readFileSync(join(RUN_HOME, 'rate-limited-until'), 'utf8').trim()); if (until > now) wall = `rate-limited (resumes ${new Date(until * 1000).toLocaleTimeString()})`; } catch {}

const sinceTxt = last ? `since ${new Date(last * 1000).toLocaleString()}` : 'first report';
const counts = buckets.unsupported
  ? `• board counts n/a — the digest doesn't support tracker.kind=${buckets.unsupported} yet (check the board directly)`
  : `• in-flight (dev/QA): ${buckets.inflight}   • queued: ${buckets.queued}
• ⏳ awaiting you (gates): ${buckets.awaiting_human}   • 🛑 blocked: ${buckets.blocked}
• ✅ done: ${buckets.done}`;
const digest =
`📊 *autoDev digest — ${cfg.client_name || ''}* (${sinceTxt})
${counts}   • commits ${last ? 'this window' : '(recent)'}: ${merged}
• engine: ${wall}`;

// --- deliver ---
const dest = rep.destination || 'log';
async function deliver() {
  if (dest === 'slack') {
    const hook = rep.slack_webhook || process.env.SLACK_WEBHOOK;
    if (!hook) { console.error('report: destination slack but no slack_webhook'); return; }
    await fetch(hook, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text: digest }) });
  } else if (dest === 'linear') {
    if (token && rep.linear_issue) {
      const id = rep.linear_issue;
      await gql('mutation($i:CommentCreateInput!){commentCreate(input:$i){success}}', { i: { issueId: id, body: digest } });
    } else console.error('report: destination linear but no linear_issue/token');
  }
  // always keep a local copy
  try { mkdirSync(join(RUN_HOME, 'logs'), { recursive: true }); appendFileSync(join(RUN_HOME, 'logs', 'report.log'), `\n${new Date().toISOString()}\n${digest}\n`); } catch {}
}
await deliver();
writeFileSync(marker, String(now)); // reset the cadence window
console.log(digest);
