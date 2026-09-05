// autoDev — Agency: the model-neutral roles (PRD §9, Milestone 6).
//
// A role says WHAT a kind of work is — purpose, responsibilities, permissions,
// required context, expected outputs. It never names a model or an executor:
// `eligible_executors: ['*']` is the only executor-related field, and a
// deployment resolves each role to an executor + a persona at run time. Personas
// (the specialist instruction sets from agency-agents) are attached through the
// deployment's `personas.*` routing, so the same role can wear a different
// specialist per client.
//
// Canonical store: <data root>/agents/roles/<id>.json overrides merge over the
// built-ins below (src/core/paths.mjs ▸ agentsDir). Nothing here reads
// ~/.claude/agents.

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { agentsDir } from '../core/paths.mjs';

export const BUILTIN_ROLES = Object.freeze([
  {
    id: 'intake', name: 'Intake Agent',
    purpose: 'Turn a plain-English request into a classified, complete brief — the only way work enters.',
    responsibilities: ['classify feature / bug / task / brief / BYO-PRD / adopt', 'interview until problem, users, solution, priority and timeline are known', 'honor intake.bugs (triage vs repro-first pipeline)', 'never build, never create stories or branches'],
    permissions: { repository: 'read', tests: false, git_commit: false, git_push: false, board: 'write' },
    required_context: ['deployment config', 'board state', 'conventions'],
    outputs: ['brief', 'feature-request issue', 'classification'],
    persona_from: 'stage_defaults.prd',
  },
  {
    id: 'product_manager', name: 'Product Manager',
    purpose: 'Author the PRD with testable acceptance criteria and stop at Gate 1.',
    responsibilities: ['problem · metrics · user stories · testable acceptance criteria · edge cases · non-goals · risks', 'ask, don\'t invent — every gap is a question to the operator', 'stop at PRD Review (H); never cross Gate 1'],
    permissions: { repository: 'read', tests: false, git_commit: true, git_push: false, board: 'write' },
    required_context: ['brief', 'codebase map', 'conventions', 'prior decisions'],
    outputs: ['prd.md', 'gate-1 summary', 'open questions'],
    persona_from: 'stage_defaults.prd',
  },
  {
    id: 'codebase', name: 'Codebase Agent',
    purpose: 'Map the relevant area of an unfamiliar codebase for the planning roles.',
    responsibilities: ['locate the code a requirement touches', 'surface existing patterns, generated types, design-system tokens, reusable utilities', 'state only what the code shows'],
    permissions: { repository: 'read', tests: false, git_commit: false, git_push: false, board: 'read' },
    required_context: ['requirement', 'conventions'],
    outputs: ['codebase map', 'relevant files', 'conventions to honor'],
    persona_from: 'roster:codebase-onboarding-engineer',
  },
  {
    id: 'project_manager', name: 'Project Manager',
    purpose: 'Decompose an approved PRD into self-contained, dependency-ordered stories.',
    responsibilities: ['coherent epics (lanes) and small single-purpose stories', 'copy the full spec into each story — the dev never opens a planning tool', 'set risk class, persona routing, AI-QA + manual test steps, blocked-by relations', 'apply the instance label to every issue'],
    permissions: { repository: 'read', tests: false, git_commit: false, git_push: false, board: 'write' },
    required_context: ['prd', 'codebase map', 'dev routing', 'board state'],
    outputs: ['epics', 'stories', 'dependency graph'],
    persona_from: 'stage_defaults.breakdown',
  },
  {
    id: 'architect', name: 'Architect',
    purpose: 'Decide structure before code: boundaries, data flow, integration points, migration risk.',
    responsibilities: ['preserve existing architecture and conventions', 'name the trade-offs explicitly', 'flag ambiguity as a requirements gap, never a coin-flip'],
    permissions: { repository: 'read', tests: false, git_commit: false, git_push: false, board: 'write' },
    required_context: ['prd', 'codebase map', 'prior decisions', 'conventions'],
    outputs: ['design notes', 'decisions', 'risks'],
    persona_from: 'roster:software-architect',
  },
  {
    id: 'implementation', name: 'Implementation Agent',
    purpose: 'Implement one approved story in its own worktree, with tests, preserving architecture.',
    responsibilities: ['implement approved tasks only — minimize unrelated changes', 'survey conventions before writing: generated types, theme tokens, reuse, comment density', 'add tests for every acceptance criterion', 'repro-test-first for bug stories', 'a requirements gap → Blocked with the specific question, never an interpretation'],
    permissions: { repository: 'write', tests: true, git_commit: true, git_push: false, board: 'write' },
    required_context: ['story (self-contained spec)', 'prd', 'coding standards', 'team AGENTS.md / CLAUDE.md', 'conventions', 'known failures', 'previous attempts'],
    outputs: ['implementation summary', 'changed files', 'tests', 'decisions', 'blockers'],
    persona_from: 'dev_routing',
  },
  {
    id: 'test', name: 'Test Agent',
    purpose: 'Prove the story meets its criteria and nothing else broke — conformance and regression.',
    responsibilities: ['run the exact configured test layers, verbatim', 'judge against the documented baseline, not zero', 'tests-for-criteria present; missing or never-red repro tests are gating fails', 'exercise it live; live browser evidence is advisory'],
    permissions: { repository: 'read', tests: true, git_commit: false, git_push: false, board: 'write' },
    required_context: ['story', 'diff', 'test layers', 'known baseline', 'hermetic env'],
    outputs: ['conformance verdict', 'regression verdict', 'evidence', 'defects'],
    persona_from: 'qa_angles.conformance+regression',
  },
  {
    id: 'review', name: 'Review Agent',
    purpose: 'Independent code review of a diff against its criteria and the house conventions.',
    responsibilities: ['builder ≠ reviewer: fresh context, re-derive the verdict from artifacts', 'correctness, maintainability, convention adherence, leanness', 'behavior-preserving simplifications only at close-out'],
    permissions: { repository: 'read', tests: true, git_commit: false, git_push: false, board: 'write' },
    required_context: ['story', 'diff', 'conventions', 'coding standards'],
    outputs: ['review verdict', 'defects', 'suggested simplifications'],
    persona_from: 'qa_angles.conformance',
  },
  {
    id: 'security_review', name: 'Security Review Agent',
    purpose: 'Adversarial angle: edge cases, malicious inputs, error paths, injection, authz, data exposure.',
    responsibilities: ['attack the change, not the author', 'every finding traceable to an input and an observation', 'real defects gate; theoretical ones flag'],
    permissions: { repository: 'read', tests: true, git_commit: false, git_push: false, board: 'write' },
    required_context: ['story', 'diff', 'hermetic env'],
    outputs: ['adversarial verdict', 'findings'],
    persona_from: 'qa_angles.adversarial',
  },
  {
    id: 'verification', name: 'Verification Agent',
    purpose: 'Combine the angles into one evidence-backed verdict; refuse to certify what is not proven.',
    responsibilities: ['default to NEEDS WORK; certify only on overwhelming evidence', 'ask "did we hallucinate this?" of every claim', 'can\'t evaluate → Blocked immediately, never a guess'],
    permissions: { repository: 'read', tests: true, git_commit: false, git_push: false, board: 'write' },
    required_context: ['all angle reports', 'evidence artifacts', 'acceptance criteria', 'ci status'],
    outputs: ['verdict', 'gating defects', 'advisory flags'],
    persona_from: 'qa_angles.verdict',
  },
]);

// ---- persona resolution from the deployment's personas.* routing --------------------
function personasFor(role, personas = {}) {
  const roster = personas.roster || [];
  const src = role.persona_from || '';
  const pick = (v) => (Array.isArray(v) ? v : v ? [v] : []);
  if (src.startsWith('stage_defaults.')) return pick(personas.stage_defaults?.[src.split('.')[1]]);
  if (src.startsWith('roster:')) { const slug = src.slice(7); return roster.includes(slug) ? [slug] : []; }
  if (src === 'dev_routing') return [...new Set((personas.dev_routing || []).map((r) => r.persona).filter(Boolean))];
  if (src.startsWith('qa_angles.')) return [...new Set(src.slice(10).split('+').flatMap((a) => pick(personas.qa_angles?.[a])))];
  return [];
}

// ---- store overrides -------------------------------------------------------------------
function readOverride(id, env) {
  const p = join(agentsDir(env), 'roles', `${id}.json`);
  if (!existsSync(p)) return null;
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch (e) { throw new Error(`agency: ${p} is not valid JSON (${e.message})`); }
}

const EXECUTOR_WORDS = /\b(claude|codex|anthropic|openai|gemini|gpt)\b/i;
// The team's convention files are named CLAUDE.md / AGENTS.md by Claude Code
// convention; mentioning those FILES is not naming an executor.
const TEAM_DOC_FILES = /\b(CLAUDE|AGENTS)\.md\b/g;
export function assertNeutral(role) {
  const text = JSON.stringify({ ...role, eligible_executors: undefined }).replace(TEAM_DOC_FILES, 'team-doc');
  if (EXECUTOR_WORDS.test(text)) throw new Error(`agency: role "${role.id}" names an executor/model — roles are model-neutral (put executor specifics in the executor adapter)`);
  return role;
}

// Every role, resolved for this deployment: built-in ← store override, with the
// personas the deployment routes to it and a fallback for anything unresolved.
export function loadRoles({ cfg = {}, env } = {}) {
  const fallback = cfg.personas?.fallback || 'general-purpose';
  return BUILTIN_ROLES.map((base) => {
    const over = readOverride(base.id, env) || {};
    const role = { ...base, ...over, permissions: { ...base.permissions, ...(over.permissions || {}) }, eligible_executors: over.eligible_executors || ['*'] };
    assertNeutral(role);
    const personas = over.personas || personasFor(role, cfg.personas);
    return { ...role, personas: personas.length ? personas : [fallback], fallback, overridden: Object.keys(over).length > 0 };
  });
}
export function loadRole(id, opts) {
  const r = loadRoles(opts).find((x) => x.id === id);
  if (!r) throw new Error(`agency: unknown role "${id}" (${BUILTIN_ROLES.map((x) => x.id).join(', ')})`);
  return r;
}

// The role block an executor adapter puts in front of a job's task — the part of
// the instructions that belongs to autoDev, not to the persona.
export function renderRoleBrief(role) {
  const p = role.permissions;
  return [
    `# Role: ${role.name} (${role.id})`,
    `Purpose: ${role.purpose}`,
    '', 'Responsibilities:', ...role.responsibilities.map((r) => `- ${r}`),
    '', `Permissions: repository ${p.repository} · tests ${p.tests ? 'execute' : 'no'} · git commit ${p.git_commit ? 'yes' : 'no'} · git push ${p.git_push ? 'yes' : 'NEVER'} · board ${p.board}`,
    `Expected outputs: ${role.outputs.join(' · ')}`,
    `Required context: ${role.required_context.join(' · ')}`,
  ].join('\n');
}
