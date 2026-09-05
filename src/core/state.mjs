// autoDev — the sidecar STATE repository (decision D2, Milestone 5A).
//
// Workflow reality (registry, project metadata, boards, events) lives in one git
// repository under the data root — <root>/state/ — never in the application repo
// and never in Brain. Durability and cross-machine continuity come from syncing
// that repo to a PRIVATE bare remote (the Mac mini: ~/Library/Application
// Support/autoDev/state.git over SSH/Tailscale).
//
//   atomic local write → append event → state commit → push/sync
//
// v1 rule: ONE active writer per project. A machine takes over explicitly
// (`autodev state takeover`) after pulling the latest state; a diverged remote is
// surfaced, never auto-merged. Runtime scratch (projects/*/runtime, locks) is
// ignored by the state repo.

import { existsSync, mkdirSync, writeFileSync, readFileSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { hostname } from 'node:os';
import { spawnSync } from 'node:child_process';
import { stateDir } from './paths.mjs';

const IGNORE = ['projects/*/runtime/', 'projects/*/locks/', 'projects/*/.last_report', '*.tmp', '.DS_Store', ''].join('\n');
const IDENTITY = ['-c', 'user.name=autodev-state', '-c', 'user.email=autodev-state@local', '-c', 'commit.gpgsign=false'];

export class StateError extends Error {}

export class StateRepo {
  #dir; #env; #machine;
  constructor({ env = process.env, dir } = {}) { this.#env = env; this.#dir = dir || stateDir(env); this.#machine = env.AUTODEV_MACHINE || hostname().split('.')[0]; }
  get dir() { return this.#dir; }
  get machine() { return this.#machine; }
  #git(args, { check = false } = {}) {
    const r = spawnSync('git', [...IDENTITY, ...args], { cwd: this.#dir, encoding: 'utf8', env: { ...this.#env, GIT_TERMINAL_PROMPT: '0' } });
    if (r.status !== 0 && check) throw new StateError(`git ${args.join(' ')}: ${(r.stderr || r.stdout).trim()}`);
    return r.status === 0 ? r.stdout.replace(/\n$/, '') : null;
  }
  isRepo() { return existsSync(join(this.#dir, '.git')); }

  // Idempotent: makes <root>/state a git repo with the ignore rules and one commit.
  init() {
    mkdirSync(this.#dir, { recursive: true });
    if (!this.isRepo()) { this.#git(['init', '-q', '-b', 'main'], { check: true }); }
    const gi = join(this.#dir, '.gitignore');
    if (!existsSync(gi) || readFileSync(gi, 'utf8') !== IGNORE) writeFileSync(gi, IGNORE);
    const readme = join(this.#dir, 'README.md');
    if (!existsSync(readme)) writeFileSync(readme, '# autoDev sidecar state\n\nWorkflow reality for the projects autoDev works on: registry, project metadata, boards, events.\nManaged by `autodev state …`. Never the application repository; never Brain.\n');
    if (!this.#git(['rev-parse', '--verify', 'HEAD'])) {   // first commit: only the repo's own files
      this.#git(['add', '.gitignore', 'README.md'], { check: true });
      this.#git(['commit', '-q', '-m', `state: initialized [${this.#machine}]`], { check: true });
    }
    return this.#dir;
  }

  // Commits everything pending. Returns the sha or null when nothing changed.
  commit(message) {
    if (!this.isRepo()) this.init();
    this.#git(['add', '-A'], { check: true });
    if ((this.#git(['status', '--porcelain']) || '') === '') return null;
    this.#git(['commit', '-q', '-m', `${message} [${this.#machine}]`], { check: true });
    return this.#git(['rev-parse', '--short', 'HEAD']);
  }

  remote() { return this.#git(['remote', 'get-url', 'origin']); }
  setRemote(url) {
    if (!this.isRepo()) this.init();
    if (this.remote()) this.#git(['remote', 'set-url', 'origin', url], { check: true }); else this.#git(['remote', 'add', 'origin', url], { check: true });
    return url;
  }

  // Fast-forward only. A diverged remote means another machine wrote without a
  // takeover; that is surfaced, not merged.
  pull() {
    if (!this.remote()) return { pulled: false, reason: 'no remote configured' };
    const fetch = spawnSync('git', [...IDENTITY, 'fetch', '-q', 'origin', 'main'], { cwd: this.#dir, encoding: 'utf8', env: { ...this.#env, GIT_TERMINAL_PROMPT: '0' } });
    if (fetch.status !== 0) return { pulled: false, reason: `fetch failed: ${(fetch.stderr || '').trim().split('\n').pop()}` };
    const remoteSha = this.#git(['rev-parse', 'origin/main']);
    if (!remoteSha) return { pulled: false, reason: 'remote has no main yet' };
    const local = this.#git(['rev-parse', 'HEAD']);
    if (remoteSha === local) return { pulled: true, changed: false };
    if (this.#git(['merge-base', '--is-ancestor', remoteSha, local]) !== null) return { pulled: true, changed: false, ahead: true };
    if (this.#git(['merge-base', '--is-ancestor', local, remoteSha]) === null) return { pulled: false, diverged: true, reason: `diverged: local ${local.slice(0, 7)} and remote ${remoteSha.slice(0, 7)} both have new commits — another machine wrote without a takeover; resolve in ${this.#dir}` };
    this.#git(['merge', '-q', '--ff-only', 'origin/main'], { check: true });
    return { pulled: true, changed: true, to: remoteSha.slice(0, 7) };
  }
  push() {
    if (!this.remote()) return { pushed: false, reason: 'no remote configured' };
    const r = spawnSync('git', [...IDENTITY, 'push', '-q', '-u', 'origin', 'main'], { cwd: this.#dir, encoding: 'utf8', env: { ...this.#env, GIT_TERMINAL_PROMPT: '0' } });
    if (r.status !== 0) return { pushed: false, reason: (r.stderr || '').trim().split('\n').filter(Boolean).pop() || 'push failed' };
    return { pushed: true };
  }
  // pull (ff-only) then push; the one command a machine runs before and after work.
  sync() {
    const pull = this.pull();
    if (pull.diverged) return { ok: false, pull, push: { pushed: false, reason: 'not pushed: diverged' } };
    const push = this.push();
    return { ok: !pull.reason || pull.pulled, pull, push };
  }
  status() {
    if (!this.isRepo()) return { initialized: false };
    const dirty = (this.#git(['status', '--porcelain']) || '').split('\n').filter(Boolean).length;
    const head = this.#git(['rev-parse', '--short', 'HEAD']);
    const remote = this.remote();
    let ahead = null, behind = null;
    if (remote && this.#git(['rev-parse', '--verify', 'origin/main'])) {
      const counts = this.#git(['rev-list', '--left-right', '--count', 'HEAD...origin/main']);
      if (counts) [ahead, behind] = counts.split(/\s+/).map(Number);
    }
    return { initialized: true, dir: this.#dir, head, dirty, remote, ahead, behind, machine: this.#machine };
  }

  // ---- one active writer per project (advisory, explicit takeover) ----
  lockPath(projectId) { return join(this.#dir, 'projects', projectId, 'writer.json'); }
  writer(projectId) { try { return JSON.parse(readFileSync(this.lockPath(projectId), 'utf8')); } catch { return null; } }
  // Claims the writer seat for this machine. Refuses when another machine holds it
  // unless { takeover: true }. The seat file IS state (synced), so the other machine
  // sees the takeover on its next pull.
  claim(projectId, { takeover = false } = {}) {
    const cur = this.writer(projectId);
    if (cur && cur.machine !== this.#machine && !takeover) throw new StateError(`project ${projectId} is being written by ${cur.machine} since ${cur.since} — run \`autodev state takeover\` on this machine after syncing (one active writer per project)`);
    mkdirSync(join(this.#dir, 'projects', projectId), { recursive: true });
    const seat = { machine: this.#machine, since: cur?.machine === this.#machine ? cur.since : new Date().toISOString(), took_over_from: cur && cur.machine !== this.#machine ? cur.machine : null };
    writeFileSync(this.lockPath(projectId), JSON.stringify(seat, null, 2) + '\n');
    return seat;
  }
  release(projectId) { try { unlinkSync(this.lockPath(projectId)); } catch {} }
}

// Commit helper every mutating core call uses; a missing state repo is created.
export function stateCommit(message, env) {
  try { return new StateRepo({ env }).commit(message); } catch (e) { return { error: e.message }; }
}
