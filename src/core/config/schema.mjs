// autoDev — THE authoritative deployment config schema (Milestone 5).
//
// One declarative definition of every key in .autodev/deployment.json (+ the
// machine-local deployment.local.json). Everything else derives from or is tested
// against it: reference/deployment.example.json must agree leaf-for-leaf
// (tests/suite/config.sh), doctor validates real configs with it, upgrade-config
// adds what it declares, and the v3 CLI reads defaults from it.
//
// Field options:
//   default    value a fresh deployment gets (the example file carries the same value)
//   identity   per-deployment value (name, repo, commands, routing) — never copied
//              from the example into a real config, and omitted from defaults()
//   local      lives in deployment.local.json, never committed
//   legacy     still accepted; superseded by another key (see normalize())
//   doc        one-line meaning (the example's _note carries the long form)
//
// Zero dependencies, by decision D1.

// ---- tiny schema DSL ---------------------------------------------------------------
const f = (type, opts = {}) => ({ type, ...opts });
export const str  = (dflt, o) => f('string',  { default: dflt, ...o });
export const bool = (dflt, o) => f('boolean', { default: dflt, ...o });
export const int  = (dflt, o) => f('integer', { default: dflt, ...o });
export const enm  = (values, dflt, o) => f('enum', { values, default: dflt, ...o });
export const list = (item, dflt, o) => f('array',  { item, default: dflt, ...o });
export const obj  = (fields, o) => f('object', { fields, ...o });
export const map  = (value, dflt, o) => f('map', { value, default: dflt, ...o }); // free keys

// The canonical pipeline stages — identical in every tracker (portability).
export const STAGES = Object.freeze({
  new_request:                { name: 'New Request',       human: false, role: 'drop zone / inbox (linear mode)' },
  clarifying:                 { name: 'Clarifying (H)',    human: true,  role: 'engine asked a question; awaiting operator reply' },
  prd_review:                 { name: 'PRD Review (H)',    human: true,  role: 'Gate 1 — PRD drafted, awaiting approve' },
  breakdown:                  { name: 'Breakdown',         human: false, role: 'decomposing the approved PRD into stories' },
  ready_for_ai_dev:           { name: 'Ready for AI Dev',  human: false, role: 'stories queued + ai-eligible' },
  ai_development:             { name: 'AI Development',    human: false, role: 'engine coding' },
  ai_qa:                      { name: 'AI QA',             human: false, role: 'three-angle QA running' },
  ready_for_human_review:     { name: 'Human Review (H)',  human: true,  role: 'Gate 2 — draft PR + manual script, awaiting approve' },
  ready_for_human_acceptance: { name: 'Human Review (H)',  human: true,  role: 'per_feature: whole-feature acceptance (same column)' },
  blocked:                    { name: 'Blocked (H)',       human: true,  role: 'stuck mid-pipeline; needs human input' },
  done:                       { name: 'Done',              human: false, role: 'merged / shipped' },
});
export const GATES = Object.freeze({ gate1: 'prd_review', gate2: ['ready_for_human_review', 'ready_for_human_acceptance'] });

const stageStatuses = (withName) => obj(Object.fromEntries(Object.entries(STAGES).map(([k, s]) => [k, obj({
  ...(withName ? { name: str(s.name) } : {}),
  id: str('FILL_AT_SETUP', { identity: true, doc: 'tracker-side state id (Linear UUID / Shortcut int); local kind ignores it' }),
  ...(s.human ? { human: bool(true) } : {}),
})])));

const projectStatus = (name, type, human) => obj({ name: str(name), id: str('FILL_IF_PROJECT_MODE', { identity: true }), type: enm(['backlog', 'planned', 'started', 'completed'], type), ...(human ? { human: bool(true) } : {}) });

// ---- the schema --------------------------------------------------------------------
export const SCHEMA = obj({
  client_name:    str('AcmeCo', { identity: true, doc: 'deployment / company name; also the tracker instance-label slug source' }),
  assistant_name: str('Marj',   { identity: true, doc: 'the concierge’s friendly name in sessions' }),
  session_mode:   enm(['concierge', 'signal', 'silent'], 'concierge', { doc: 'how much autoDev greets a new session in this repo' }),
  bot_identity:   obj({ name: str('autodev-bot', { identity: true }), email: str('autodev-bot@example.com', { identity: true }) }, { identity: true, doc: 'git commit author for engine commits' }),
  repo: obj({
    url:                   str('https://github.com/AcmeCo/their-repo', { identity: true }),
    default_branch:        str('main', { identity: true, doc: 'only humans merge this branch' }),
    feature_branch_prefix: str('feature/', { identity: true }),
    story_branch_prefix:   str('autodev', { identity: true }),
    local_path:            str('', { local: true, doc: 'absolute clone path on THIS machine (deployment.local.json)' }),
  }, { identity: true }),
  merge_policy: obj({ story_to_feature: enm(['squash', 'merge_commit', 'rebase'], 'squash'), feature_to_main: enm(['squash', 'merge_commit', 'rebase'], 'merge_commit') }),

  tracker: obj({
    kind:           enm(['local', 'linear', 'shortcut'], 'local', { doc: 'WHERE the board (the only workflow state machine) lives' }),
    instance_label: str('autodev:acmeco', { identity: true, doc: 'ownership tag on a shared board; every read/write filters to it' }),
    mcp:            str('mcp__linear', { doc: 'MCP server prefix used for Linear reads in-session' }),
    team:           str('AcmeCo Engineering', { identity: true }),
    team_key:       str('ACME', { identity: true }),
    team_id:        str('FILL_AT_SETUP', { identity: true }),
    api_token_env:  str('LINEAR_API_TOKEN'),
    mapping: obj({
      feature:    str('Linear Project'),
      epic:       str('Linear Milestone (within the feature\'s Project)'),
      story:      str('Linear Issue (assigned to its milestone)'),
      dependency: str('Linear issue relation (blocks / blocked_by)'),
    }, { doc: 'documentation of the vocabulary mapping; not read by code' }),
    state_model:    enm(['status'], 'status'),
    hierarchy:      enm(['issue', 'project'], 'issue', { doc: 'issue = feature rides a feature issue (default); project = feature IS a Linear Project (opt-in)' }),
    project_statuses: obj({
      new_request:    projectStatus('New Request', 'backlog'),
      clarifying:     projectStatus('Clarifying (H)', 'planned', true),
      prd_review:     projectStatus('PRD Review (H)', 'planned', true),
      in_development: projectStatus('In Development', 'started'),
      acceptance:     projectStatus('Acceptance (H)', 'started', true),
      done:           projectStatus('Shipped', 'completed'),
    }, { doc: 'hierarchy=project only' }),
    statuses: stageStatuses(true),
    labels: obj({
      ai_eligible:   str('ai-eligible'),
      route_feature: str('route:feature'),
      route_task:    str('route:task'),
      route_bug:     str('route:bug'),
      risk_classes:  list(str(), ['risk:trivial', 'risk:standard', 'risk:sensitive']),
    }),
    mirror: obj({ linear: bool(false, { doc: 'local kind only: also mirror to Linear asynchronously, best-effort' }) }),
    linear:   obj({ api_token_file: str('', { local: true }) }),
    shortcut: obj({
      api_token_env: str('SHORTCUT_API_TOKEN'),
      api_token_file: str('', { local: true }),
      workflow_id:   str('FILL_AT_SETUP', { identity: true }),
      group_id:      str('', { identity: true }),
      statuses:      stageStatuses(false),
    }),
  }),

  planning: obj({
    engine: enm(['agency', 'braingrid'], 'agency', { doc: 'who authors the PRD + breakdown: agency (product-manager / project-manager personas; default) or the BrainGrid adapter (legacy, optional)' }),
  }),
  braingrid: obj({
    enabled:          bool(false, { legacy: 'planning.engine', doc: 'LEGACY selector — planning.engine is authoritative; kept readable so old configs keep their behavior' }),
    project_short_id: str('PROJ-XX', { identity: true, doc: 'BrainGrid project id, used only when planning.engine=braingrid' }),
  }),
  executor: obj({
    default: str('claude', { doc: 'which registered executor runs jobs for this deployment (claude · codex …)' }),
  }),
  brain: obj({
    enabled:    bool(false, { doc: 'connect to a Brain instance for persistent scoped memory (M13)' }),
    project_id: str(null, { identity: true, nullable: true, doc: 'Brain project id (prj_…); null until registered' }),
    url:        str(null, { identity: true, nullable: true, doc: 'Brain API base URL; null = not configured' }),
  }),

  intake: obj({
    bugs:                 enm(['triage', 'pipeline'], 'triage'),
    mode:                 enm(['cli', 'linear', 'both'], 'cli'),
    linear_drop_status:   str('New Request'),
    authorized_operators: list(str(), [], { doc: 'linear mode: who may trigger + approve; [] = nobody; "*" = any member (explicit opt-in)' }),
  }),
  execution: obj({
    max_lanes:             int(5),
    tick_interval_minutes: int(15),
    max_dev_qa_loops:      int(3, { doc: 'stuck-detector: no-progress passes before Blocked' }),
    self_review_rounds:    int(1),
    logging:               enm(['quiet', 'normal', 'verbose'], 'normal'),
    incremental_breakdown: bool(false),
  }),
  reporting: obj({
    cadence:       str('off', { doc: 'off | hourly | <N>m | <N>h' }),
    destination:   enm(['log', 'slack', 'linear'], 'log'),
    slack_webhook: str(''),
    linear_issue:  str(''),
    feature_stats: bool(true),
  }),
  commands: obj({
    install: str('meteor npm install', { identity: true }),
    test:    str('meteor npm test', { identity: true }),
    lint:    str('meteor npm run lint', { identity: true }),
    build:   str('meteor build --debug', { identity: true }),
    app_run: str('meteor run', { identity: true }),
    app_url: str('http://localhost:3000', { identity: true }),
  }, { identity: true }),
  qa: obj({
    e2e_framework:       str('cypress', { identity: true }),
    e2e_dir:             str('e2e', { identity: true }),
    live_browser_driver: enm(['playwright_mcp', 'playwright', 'cypress'], 'playwright_mcp'),
    test_layers:         obj({ backend: str(''), ui: str(''), e2e: str('') }, { identity: true, doc: 'exact per-layer commands QA runs verbatim; "" falls back to commands.test' }),
    visual_qa: obj({
      enabled:     bool(true),
      mode:        enm(['advisory', 'gating'], 'advisory'),
      ui_globs:    list(str(), ['ui/', 'src/components', 'src/pages', '*.tsx', '*.jsx', '*.vue', '*.svelte', '*.css', '*.scss']),
      breakpoints: list(str(), ['375', '768', '1280']),
      states:      list(str(), ['default', 'hover', 'focus', 'empty', 'loading', 'error']),
    }),
    docker_up: str('docker compose up -d'),
    seed_test: str('', { identity: true }),
    hermetic: obj({
      enabled:          bool(true, { doc: 'SAFETY: never run QA against production; doctor FAILS when prod endpoints are present and this is off' }),
      env:              map(str(), { SEARCH_URL: 'http://localhost:9200', SMS_API_TOKEN: '', EMAIL_API_KEY: '' }, { identity: true, doc: 'exported before every test/build/app/live run' }),
      forbid_endpoints: list(str(), ['*.twilio.com', 'api.mailgun.net', 'api.sendgrid.com', 'api.stripe.com'], { identity: true }),
    }),
    acceptance: obj({ integrated_suites: list(str(), ['meteor npm test', 'meteor npm run test:e2e'], { identity: true }), live_system: bool(true) }),
    deep_dive:  obj({ final_review: bool(true) }),
    repro:      obj({ max_attempts: int(7), wall_clock_minutes: int(45) }),
  }),
  preview: obj({ enabled: bool(true), command: str(''), url: str('') }),
  backlog: obj({
    enabled:    bool(false),
    ask_when:   list(enm(['feature_complete', 'idle']), ['feature_complete', 'idle']),
    idle_ticks: int(4),
    batch:      int(3),
    source:     obj({ status: str('Backlog'), labels: list(str(), []), type: enm(['any', 'bug', 'feature'], 'any') }),
  }),
  review: obj({
    delivery:                     enm(['draft_pr', 'local_diff'], 'draft_pr'),
    granularity:                  enm(['per_story', 'per_feature'], 'per_story'),
    auto_merge_to_feature_branch: bool(false),
    quality_review:               bool(true),
  }),
  backup: obj({ enabled: bool(true), remote: str('origin') }),
  personas: obj({
    auto_install: bool(true),
    fallback:     str('general-purpose'),
    library:      obj({ repo: str('msitarzewski/agency-agents'), ref: str('9f3e401ccd09aa0ee0ef8e015226d0647908e01e') }),
    roster:       list(str(), ['product-manager', 'project-manager-senior', 'software-architect', 'backend-architect', 'frontend-developer', 'architect-ux', 'ui-designer', 'database-optimizer', 'git-workflow-master', 'devops-automator', 'codebase-onboarding-engineer', 'code-reviewer', 'evidence-collector', 'reality-checker', 'test-results-analyzer', 'api-tester', 'application-security-engineer', 'general-purpose']),
    stage_defaults: obj({ prd: str('product-manager'), breakdown: str('project-manager-senior') }),
    dev_routing:  list(obj({ match: str(), persona: str(), why: str('') }), [
      { match: 'server/', persona: 'backend-architect', why: 'Elixir/Phoenix · GraphQL/Absinthe · Ecto' },
      { match: 'ui/', persona: 'frontend-developer', why: 'React 18 · TypeScript · Apollo · MUI · Formik' },
      { match: 'schema|migration|ecto|query|index', persona: 'database-optimizer', why: 'DB schema / query work' },
      { match: 'design|theme|css|component-library', persona: 'architect-ux', why: 'design system / CSS architecture' },
      { match: 'default', persona: 'general-purpose', why: 'fallback when no clear specialist' },
    ], { identity: true }),
    qa_angles: obj({
      conformance:   list(str(), ['code-reviewer', 'test-results-analyzer', 'evidence-collector']),
      adversarial:   list(str(), ['application-security-engineer', 'api-tester']),
      regression:    list(str(), ['test-results-analyzer', 'reality-checker']),
      visual:        list(str(), ['evidence-collector', 'ui-designer', 'architect-ux']),
      verdict:       str('reality-checker'),
      live_evidence: str('evidence-collector'),
    }),
  }),
  runner: obj({
    home_dir:          str('~/autodev', { local: true }),
    heartbeat_file:    str('~/autodev/heartbeat', { local: true }),
    rate_limited_file: str('~/autodev/rate-limited-until', { local: true }),
    logs_dir:          str('~/autodev/logs', { local: true }),
  }, { local: true, doc: 'per-machine timer paths (deployment.local.json)' }),
  engine: obj({ mode: enm(['plugin', 'vendored'], 'plugin'), version: str('') }, { identity: true, doc: 'stamped by install.sh in vendored mode' }),
});

// ---- derived views --------------------------------------------------------------------
// Walks the schema; `visit(path, field)` for every leaf (arrays/maps count as leaves).
// `identity` and `local` are inherited: marking an object marks its whole subtree.
export function walk(field = SCHEMA, visit, path = [], inherited = {}) {
  const flags = { identity: inherited.identity || field.identity === true, local: inherited.local || field.local === true };
  if (field.type === 'object') { for (const [k, v] of Object.entries(field.fields)) walk(v, visit, [...path, k], flags); return; }
  visit(path, { ...field, ...flags });
}

export function leafPaths({ includeLocal = true, includeIdentity = true } = {}) {
  const out = [];
  walk(SCHEMA, (p, f) => {
    if (!includeLocal && f.local) return;
    if (!includeIdentity && f.identity) return;
    out.push(p.join('.'));
  });
  return out;
}

// The full default object. identity: false drops per-deployment fields (what
// upgrade-config merges UNDER an existing config); local: false drops the
// machine-local ones (they live in deployment.local.json).
export function defaults({ identity = true, local = false, field = SCHEMA } = {}) {
  if (field.type !== 'object') return field.default === undefined ? undefined : structuredClone(field.default);
  const o = {};
  for (const [k, v] of Object.entries(field.fields)) {
    if (!identity && v.identity) continue;
    if (!local && v.local) continue;
    const d = defaults({ identity, local, field: v });
    if (d !== undefined && !(v.type === 'object' && Object.keys(d).length === 0)) o[k] = d;
  }
  return o;
}

// ---- validation ------------------------------------------------------------------------
function typeOf(v) { return v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v; }

function checkLeaf(field, value, path, out) {
  const at = path.join('.');
  if (value === null || value === undefined) { if (field.nullable) return; out.errors.push(`${at}: must be a ${field.type}, got null`); return; }
  switch (field.type) {
    case 'string':  if (typeof value !== 'string') out.errors.push(`${at}: must be a string, got ${typeOf(value)}`); break;
    case 'boolean': if (typeof value !== 'boolean') out.errors.push(`${at}: must be true/false, got ${typeOf(value)} ${JSON.stringify(value)}`); break;
    case 'integer': if (!Number.isInteger(value)) out.errors.push(`${at}: must be an integer, got ${JSON.stringify(value)}`); break;
    case 'enum':    if (!field.values.includes(value)) out.errors.push(`${at}: must be one of ${field.values.join(' | ')}, got ${JSON.stringify(value)}`); break;
    case 'array':
      if (!Array.isArray(value)) { out.errors.push(`${at}: must be an array, got ${typeOf(value)}`); break; }
      value.forEach((v, i) => validateField(field.item, v, [...path, String(i)], out));
      break;
    case 'map':
      if (typeOf(value) !== 'object') { out.errors.push(`${at}: must be an object, got ${typeOf(value)}`); break; }
      for (const [k, v] of Object.entries(value)) if (!k.startsWith('_')) validateField(field.value, v, [...path, k], out);
      break;
    default: out.errors.push(`${at}: unknown schema type ${field.type}`);
  }
}

function validateField(field, value, path, out) {
  if (field.type !== 'object') return checkLeaf(field, value, path, out);
  if (typeOf(value) !== 'object') { out.errors.push(`${path.join('.') || '(root)'}: must be an object, got ${typeOf(value)}`); return; }
  for (const [k, v] of Object.entries(value)) {
    if (k.startsWith('_')) continue;                       // _note documentation keys
    const sub = field.fields[k];
    if (!sub) { out.warnings.push(`${[...path, k].join('.')}: unknown key (ignored by the engine)`); continue; }
    validateField(sub, v, [...path, k], out);
  }
}

// Cross-field rules: things a type check cannot express.
function semanticChecks(cfg, out) {
  const kind = cfg.tracker?.kind || 'local';
  if (kind === 'linear') {
    for (const [k, s] of Object.entries(cfg.tracker?.statuses || {})) if (!k.startsWith('_') && (s?.id === 'FILL_AT_SETUP' || !s?.id)) out.warnings.push(`tracker.statuses.${k}.id: not set up yet (FILL_AT_SETUP) — ops/linear-setup.md`);
    if (!cfg.tracker?.team_id || cfg.tracker.team_id === 'FILL_AT_SETUP') out.warnings.push('tracker.team_id: not set up yet (FILL_AT_SETUP)');
  }
  if (kind === 'shortcut') {
    if ((cfg.tracker?.hierarchy || 'issue') === 'project') out.errors.push('tracker.hierarchy=project needs tracker.kind=linear (project statuses are Linear-only)');
    if ((cfg.intake?.mode || 'cli') !== 'cli') out.errors.push('intake.mode=linear needs tracker.kind=linear — Shortcut deployments use cli intake');
  }
  if ((cfg.intake?.mode || 'cli') !== 'cli' && kind !== 'linear') out.errors.push(`intake.mode=${cfg.intake.mode} needs tracker.kind=linear`);
  if (cfg.review?.granularity === 'per_feature' && cfg.review?.auto_merge_to_feature_branch !== true) out.warnings.push('review.granularity=per_feature without review.auto_merge_to_feature_branch=true — stories will still wait for per-story review');
  if (cfg.qa?.hermetic?.enabled === true && Object.keys(cfg.qa.hermetic.env || {}).filter((k) => !k.startsWith('_')).length === 0) out.warnings.push('qa.hermetic.enabled but qa.hermetic.env is empty — nothing is overridden at run time');
  if (cfg.planning?.engine === 'braingrid' && (!cfg.braingrid?.project_short_id || ['PROJ-XX', 'PENDING_BRAINGRID_INIT'].includes(cfg.braingrid.project_short_id))) out.warnings.push('planning.engine=braingrid but braingrid.project_short_id is not set (run braingrid init)');
  if (cfg.brain?.enabled === true && !cfg.brain?.url) out.errors.push('brain.enabled but brain.url is not set');
}

export function validate(cfg) {
  const out = { errors: [], warnings: [] };
  validateField(SCHEMA, cfg, [], out);
  if (!out.errors.length) semanticChecks(cfg, out);
  out.ok = out.errors.length === 0;
  return out;
}

// ---- legacy normalization ----------------------------------------------------------------
// In-memory only. Makes an older config mean what it always meant under the current
// schema, without rewriting the file (upgrade-config.sh does the on-disk part):
//   braingrid.enabled=true, no planning.engine  → planning.engine=braingrid
//   no planning section                         → planning.engine=agency (the new default)
//   no executor / brain section                 → defaults
export function normalize(cfg) {
  const c = structuredClone(cfg || {});
  const notes = [];
  if (!c.planning || !c.planning.engine) {
    const legacy = c.braingrid?.enabled === true;
    c.planning = { ...(c.planning || {}), engine: legacy ? 'braingrid' : 'agency' };
    if (legacy) notes.push('planning.engine derived from legacy braingrid.enabled=true (set planning.engine explicitly to silence)');
  }
  if (!c.executor?.default) c.executor = { ...(c.executor || {}), default: 'claude' };
  if (!c.brain) c.brain = defaults().brain;
  if (c.tracker && !c.tracker.kind) { c.tracker.kind = 'linear'; notes.push('tracker.kind missing — pre-local configs mean linear'); }
  return { cfg: c, notes };
}
