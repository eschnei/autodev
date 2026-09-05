// autoDev — core tracker interface (Milestone 4). Wraps the v2 facade
// scripts/tracker.mjs rather than rewriting it: every WRITE still goes through the
// facade (it owns history, notes-as-comments, the Linear mirror queue, and the
// linear/shortcut delegation), so v2 skills and v3 core can never disagree about
// the board. READS of the local board are direct JSON reads — no subprocess — so
// deterministic workflow logic (gates, selection) can run without an LLM and
// without spawning.
//
// Board issue shape (local kind): { id, title, description, stage, labels[],
//   project, milestone, relations[], attachments[], comments[], history[],
//   linear_id, created_at, updated_at }

import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { stateCommit } from './state.mjs';

const FACADE = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'scripts', 'tracker.mjs');

export class TrackerError extends Error {}

export class Tracker {
  #root; #configPath; #cfg; #boardDir; #sidecar;
  // boardDir: the sidecar board (v3-native projects) — omitted for a v2 deployment,
  // whose board sits next to its .autodev/deployment.json
  constructor({ repoRoot, configPath, cfg, boardDir }) {
    this.#root = repoRoot;
    this.#configPath = configPath || join(repoRoot, '.autodev', 'deployment.json');
    this.#cfg = cfg || {};
    this.#boardDir = boardDir || join(dirname(this.#configPath), 'board');
    this.#sidecar = !!boardDir;
  }
  static for(ctx) {   // from a CLI/tick context: sidecar board when the project is v3-native
    const sidecar = ctx.project?.tracker?.mode === 'sidecar' ? ctx.project.tracker.location : undefined;
    return new Tracker({ repoRoot: ctx.identity.root, configPath: ctx.legacy?.configPath, cfg: ctx.legacy || {}, boardDir: sidecar });
  }
  get kind() { return this.#cfg.tracker?.kind || 'local'; }
  get boardDir() { return this.#boardDir; }
  get sidecar() { return this.#sidecar; }
  // env a v2 script needs to see the same board this Tracker sees
  get env() { return { AUTODEV_CONFIG: this.#configPath, ...(this.#sidecar ? { AUTODEV_BOARD_DIR: this.#boardDir } : {}) }; }
  get instanceLabel() { return this.#cfg.tracker?.instance_label || null; }

  // ---- reads (local kind: direct, no subprocess) ----
  readIssues() {
    if (this.kind !== 'local') throw new TrackerError(`direct board reads need tracker.kind=local (this deployment: ${this.kind})`);
    if (!existsSync(this.boardDir)) return [];
    return readdirSync(this.boardDir)
      .filter((f) => f.endsWith('.json') && !f.startsWith('_') && !f.startsWith('.'))
      .map((f) => { try { return JSON.parse(readFileSync(join(this.boardDir, f), 'utf8')); } catch { return null; } })
      .filter(Boolean)
      .sort((a, b) => Number(a.id.split('-')[1]) - Number(b.id.split('-')[1]));
  }
  // Own lane (manual principle 10): only issues carrying this instance's label —
  // unless the deployment has no label configured (single-tenant local board).
  ownIssues() {
    const label = this.instanceLabel;
    const all = this.readIssues();
    return label ? all.filter((i) => (i.labels || []).includes(label)) : all;
  }
  issue(id) { return this.readIssues().find((i) => i.id.toLowerCase() === String(id).toLowerCase()) || null; }
  inStage(stage) { return this.ownIssues().filter((i) => i.stage === stage); }

  // ---- writes (always through the facade) ----
  #run(args) {
    const r = spawnSync('node', [FACADE, ...args], { cwd: this.#root, env: { ...process.env, ...this.env }, encoding: 'utf8' });
    if (r.status !== 0) throw new TrackerError((r.stderr || r.stdout || `tracker.mjs ${args[0]} failed`).trim());
    if (this.#sidecar && !['state-id', 'doctor', 'whoami'].includes(args[0])) stateCommit(`board: ${args.slice(0, 3).join(' ')}`);
    return r.stdout.trim();
  }
  createIssue({ title, desc, stage, labels, project, milestone }) {
    const a = ['create-issue', '--title', title];
    if (desc) a.push('--desc', desc);
    if (stage) a.push('--stage', stage);
    if (labels?.length) a.push('--labels', labels.join(','));
    if (project) a.push('--project', project);
    if (milestone) a.push('--milestone', milestone);
    return this.#run(a).split('\n').pop();
  }
  move(id, stage, note) { return this.#run(note ? ['move', id, stage, '--note', note] : ['move', id, stage]); }
  comment(id, body) { return this.#run(['comment', id, body]); }
  relate(id, related, type = 'blocks') { return this.#run(['relate', id, related, '--type', type]); }
  attach(id, url, title) { return this.#run(title ? ['attach', id, url, '--title', title] : ['attach', id, url]); }
  update(id, fields) {
    const a = ['update-issue', id];
    for (const [k, v] of Object.entries(fields)) if (v != null) a.push(`--${k}`, Array.isArray(v) ? v.join(',') : String(v));
    return this.#run(a);
  }
  stateName(key) { return this.#run(['state-id', key]); }
  doctor() { return this.#run(['doctor']); }
  flushMirror() { return this.#run(['flush-mirror']); }
}
