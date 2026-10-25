/**
 * DevPanel API contract v1 — shared by daemon, CLI and UI.
 *
 * Prose semantics live in contract/api.md; this file is the machine-checked shape.
 * Both must change together, and only through contract/CHANGES.md (see AGENTS.md).
 */

export const API_VERSION = 1 as const;
export const API_BASE = '/api/v1' as const;

/** Header every mutating request must carry (CSRF guard + audit of who asked). */
export const CLIENT_HEADER = 'X-DevPanel-Client' as const;
export type ClientKind = 'ui' | 'cli';
/**
 * v1.3-C. Optional self-reported agent name on CLI requests, /^[a-z0-9][a-z0-9._-]{0,31}$/
 * (otherwise 400 BAD_REQUEST). Ignored on ui requests. A label, not authentication.
 */
export const AGENT_HEADER = 'X-DevPanel-Agent' as const;
/** v1.5-C: self-reported work context, never authentication. Label is URI encoded on the wire. */
export const TASK_HEADER = 'X-DevPanel-Task' as const;
export const TASK_LABEL_HEADER = 'X-DevPanel-Task-Label' as const;

// ───────────────────────── IDs & primitives ─────────────────────────

/** "p_" + 10 lowercase base32 chars. Stable for the life of the project. */
export type ProjectId = string;
/** User-chosen slug, /^[a-z][a-z0-9-]{0,31}$/, unique within its project. */
export type ServiceId = string;
/** "r_" + ULID. A new one each time a managed process is actually spawned. */
export type RunId = string;
/** "op_" + ULID. */
export type OperationId = string;
/** ISO-8601 UTC with milliseconds, e.g. "2026-10-20T02:42:07.118Z". */
export type Timestamp = string;

// ───────────────────────── Config ─────────────────────────

/**
 * In requests: a plain string, or a secret.
 *   { secret: true, value: "..." }  sets / replaces a secret
 *   { secret: true }                keeps the currently stored secret value
 * Standalone /config/validate accepts a missing value without project context.
 * Register/update require an existing secret at the same project/service key; new keys must supply value.
 * In responses secrets are always returned as { secret: true } with no value.
 */
export type EnvValue = string | { secret: true; value?: string };
export type EnvMap = Record<string, EnvValue>;

// ───────────────────────── Params (v1.1-A) ─────────────────────────

/** Rendered by clients as: string → text field, number → number field, boolean → switch, enum → single choice. */
export type ParamType = 'string' | 'number' | 'boolean' | 'enum';
/** Derived from X-DevPanel-Client of the request that changed it: ui → user, cli → agent. */
export type ParamSetter = 'agent' | 'user';
export type ParamValue = string | number | boolean;

export interface ParamChoice {
  value: string;
  label?: string;
  description?: string;
}

/**
 * An adjustable piece of configuration, usually created by an agent and tuned by a human.
 * Referenced as ${key} in services[].command[*] and in non-secret env values; "$${" is a literal "${".
 * Only keys matching /^[a-zA-Z][a-zA-Z0-9_]{0,31}$/ are placeholders; shell forms
 * such as ${a:-b}, ${}, and unclosed ${ remain literal. Valid unknown keys are PARAM_UNKNOWN.
 * For sh/bash/zsh -c/-…c, only the immediately following script argv gets shell quoting;
 * later positional argv elements are substituted without extra quotes.
 * Inline escapes inserted ${ as $${; secret env inline expands the entire value before marking secret.
 * Substituted at start time only; saving never starts or restarts anything.
 */
export interface ParamConfig {
  /** /^[a-zA-Z][a-zA-Z0-9_]{0,31}$/, unique within the project. */
  key: string;
  label: string;
  type: ParamType;
  /**
   * string/enum → string, number → number, boolean → boolean.
   * Secret params: a request with value sets it, without value keeps the stored one; responses never include it.
   */
  value?: ParamValue;
  description?: string;
  /** enum only, at least one; value must be one of choices[].value. */
  choices?: ParamChoice[];
  /** number only. */
  min?: number;
  max?: number;
  secret?: boolean;
  // ── response-only; ignored in requests ──
  /** Who last set value. */
  setBy?: ParamSetter;
  valueUpdatedAt?: Timestamp;
  /** Who last edited label / description / choices / min / max. */
  describedBy?: ParamSetter;
  usedBy?: ParamReference[];
}

export interface ParamReference {
  /** "*" for project-level env; "action:<actionId>" for a quick action (v1.2-C). */
  serviceId: ServiceId | '*';
  /** v1.3-A adds 'ready' (ready.check.port of serviceId); clients treat this as an open enum. */
  where: 'command' | 'env' | 'ready';
  /** argv index when where = command. */
  index?: number;
  /** variable name when where = env. */
  envKey?: string;
}

export interface ServiceConfig {
  id: ServiceId;
  name: string;
  /** Relative to the project root ("." allowed) or absolute. */
  cwd: string;
  /** argv. command[0] is a program name (looked up via the effective PATH) or a path. Never a shell string. */
  command: string[];
  env?: EnvMap;
  /** Graceful stop wait before reporting "not stopped yet". Default 10, range 1–300. */
  stopTimeoutSec?: number;
  /** v1.3-A. Absent = readiness is not judged for this service. Not compared by configChangedSinceStart. */
  ready?: ReadyConfig;
}

/**
 * v1.3-A. An observable "can accept requests" signal; not a health check.
 * log: any entry appears in one out/err line (case-sensitive substring after stripping ANSI; no regex).
 * port: a verified process of the run listens on TCP; absent port = any port. A string must be exactly
 * "${key}" referencing a non-secret number param, substituted at start time.
 * Inlining a deleted port param writes a JSON number, never a numeric string.
 */
export type ReadyCheck =
  | { kind: 'log'; /** 1–5 entries, each 1–200 chars. */ contains: string[] }
  | { kind: 'port'; /** 1–65535 or "${key}". */ port?: number | string };

export interface ReadyConfig {
  check: ReadyCheck;
  /** Default 120, range 1–900. Exceeding it only marks the run; nothing is stopped. */
  timeoutSec?: number;
}

/** Explicit directory targets; ids are unique within each list. Paths are relative to ProjectConfig.root. */
export interface RepositoryConfig { id: string; name: string; path: string; }
export interface MavenProjectConfig extends RepositoryConfig { executable?: 'auto' | 'wrapper' | 'mvn'; }

export interface ProjectConfig {
  schemaVersion: 1;
  name: string;
  /** v1.5-C: display grouping only; separate real roots retain independent project/run identities. */
  instance?: { group: string; name: string };
  /** Absolute path. The daemon stores the realpath-normalized form. */
  root: string;
  /** Applies to all services; a service's own env wins on conflict. */
  env?: EnvMap;
  /** Order is the project-level start order. At least one. */
  services: ServiceConfig[];
  /** v1.1-A. Display order = array order. */
  params?: ParamConfig[];
  /** v1.2-C. AI-defined quick actions; display order = array order. */
  actions?: ActionConfig[];
  /** v1.2-C. auto (default) = ./mvnw when present, else mvn on the effective PATH. */
  maven?: { executable?: 'auto' | 'wrapper' | 'mvn' };
  /** v1.4-A. Omitted = legacy root target; [] = no targets. No automatic discovery. */
  repositories?: RepositoryConfig[];
  mavenProjects?: MavenProjectConfig[];
}

export interface Project {
  id: ProjectId;
  /** Increments on every saved change. Used for optimistic concurrency (ifRevision). */
  revision: number;
  createdAt: Timestamp;
  updatedAt: Timestamp;
  /** Secrets masked. */
  config: ProjectConfig;
}

// ───────────────────────── Runtime state ─────────────────────────

export type ServiceState =
  | 'idle' // never run (no run on record)
  | 'starting' // spawning / within start grace window
  | 'running' // a verified managed process still exists; says nothing about health
  | 'stopping' // stop requested, waiting for exit
  | 'stopped' // ended because a user/agent asked (graceful or forced)
  | 'exited' // ended on its own with exit code 0
  | 'failed' // could not start, ended on its own with non-zero/signal, or stop failed
  | 'unknown'; // cannot verify (e.g. after daemon restart, identity check failed)

export type ExitReason =
  | 'user-stop' // graceful stop requested
  | 'force-stop' // SIGKILL requested
  | 'self-exit' // process ended without being asked
  | 'spawn-failed' // never got a process
  | 'start-cancelled' // a stop arrived before the start finished
  | 'daemon-lost' // daemon could not keep or re-verify ownership
  | 'timeout'; // v1.2-C: a task run exceeded its timeoutSec and was cancelled

/** v1.3-C. Who asked. agent is the X-DevPanel-Agent name; always null unless client = 'cli'. */
export interface Actor {
  client: ClientKind | 'daemon';
  agent: string | null;
  /** v1.5-C: optional on CLI actors; label requires taskId. Old records may omit both. */
  taskId?: string;
  taskLabel?: string;
}

export interface ExitInfo {
  reason: ExitReason;
  code: number | null;
  signal: string | null; // e.g. "SIGTERM"
  at: Timestamp;
  /**
   * v1.3-C. For user-stop / force-stop / start-cancelled (and cancelled task runs): who asked.
   * null for self-exit, spawn-failed, daemon-lost, timeout. v1.3 daemons always send it; optional for older ones.
   */
  requestedBy?: Actor | null;
}

/**
 * v1.3-A. not-configured: the service had no ready config at start. ready / timed-out /
 * ended-before-ready are final. unknown: judgement could not resume after a daemon restart.
 */
export type ReadyState = 'not-configured' | 'waiting' | 'ready' | 'timed-out' | 'ended-before-ready' | 'unknown';

export interface ReadyInfo {
  state: ReadyState;
  /** When it became ready or timed out. */
  at: Timestamp | null;
  /** ready only: milliseconds after startedAt. */
  afterMs: number | null;
  evidence: null | { kind: 'log'; seq: number } | { kind: 'port'; port: number; address: string };
}

export interface RunSummary {
  id: RunId;
  projectId: ProjectId;
  serviceId: ServiceId;
  configRevision: number;
  startedAt: Timestamp;
  endedAt: Timestamp | null;
  /** Root process (session/group leader). Null if spawn failed. */
  pid: number | null;
  state: ServiceState;
  exit: ExitInfo | null;
  /** v1.3-C. null for records from before v1.3. v1.3 daemons always send it; optional for older ones. */
  startedBy?: Actor | null;
  /** v1.3-A. Old records read as not-configured. v1.3 daemons always send it; optional for older ones. */
  ready?: ReadyInfo;
}

export interface LogInfo {
  firstSeq: number | null; // oldest retained line
  lastSeq: number | null; // newest line
  bytes: number;
  /** Older lines were dropped because of size limits. */
  truncated: boolean;
}

export interface RunDetail extends RunSummary {
  /**
   * Snapshot of what was actually executed, after ${key} substitution.
   * Fragments that came from secret params are replaced with "••••"; env values are never returned.
   */
  command: string[];
  cwd: string; // absolute
  envKeys: string[];
  /** v1.1-A. Only params referenced by this service command/effective non-secret env.
   * Overridden project env references are excluded; secret values are { secret: true }. */
  params: Record<string, ParamValue | { secret: true }>;
  log: LogInfo;
  /** Currently tracked processes; empty once ended. */
  processes: ProcessInfo[];
}

export interface ProcessInfo {
  pid: number;
  ppid: number;
  startedAt: Timestamp; // process identity = pid + startedAt
  command: string; // short name, e.g. "java"
}

export interface ServiceView {
  id: ServiceId;
  name: string;
  state: ServiceState;
  stateSince: Timestamp | null;
  /** The run that is starting / running / stopping, else null. */
  currentRun: RunSummary | null;
  /** Most recent run (may be the same as currentRun), null if never run. */
  lastRun: RunSummary | null;
  /** True while 'stopping' after the graceful timeout elapsed → offer force stop. */
  stopTimedOut: boolean;
  /** Operation currently acting on (or queued for) this service. */
  pendingOperationId: OperationId | null;
  /**
   * Effective service config (including project env, overridden by service env) differs from currentRun's startup snapshot.
   * Compare resolved cwd and defaulted stop timeout, not project revision. Project name/other services do not affect it.
   * False without currentRun or when edits restore the startup config. Secret values are compared privately.
   */
  configChangedSinceStart: boolean;
  /**
   * ErrorCode for spawn failure, exit during startup, or unverifiable state.
   * Null for self-exit after successful startup (including non-zero/signal); use lastRun.exit for the reason.
   * STOP_TIMEOUT while stopTimedOut; cleared once stopped.
   */
  error: ApiError | null;
  /** v1.3-D. Set after a ui stop while policy.holdAfterUserStop; cli start/restart is denied. */
  hold?: ServiceHold | null;
  /** v1.3-D. Listed in policy.lockedServices; every cli action is denied. */
  locked?: boolean;
}

export type ProjectAggregate =
  | 'idle' // no service has ever run
  | 'running' // all services running
  | 'partial' // some running, some not
  | 'transition' // any starting/stopping and none failed/unknown
  | 'stopped' // none running, at least one has run, none failed
  | 'failed' // any failed (and none running)
  | 'unknown'; // any unknown

export interface MavenProjectView extends MavenProjectConfig { currentRun: TaskRunSummary | null; lastRun: TaskRunSummary | null; }

export interface ProjectView {
  id: ProjectId;
  name: string;
  /** v1.5-C. Display grouping only; root/projectId remain the instance identity. */
  instance?: { group: string; name: string };
  root: string;
  revision: number;
  aggregate: ProjectAggregate;
  runningCount: number;
  serviceCount: number;
  services: ServiceView[]; // config order
  repositories?: RepositoryConfig[];
  mavenProjects?: MavenProjectView[];
  /** v1.2-C. Config order; [] when none. */
  actions: ActionView[];
  /** v1.4-A. Aggregate across Maven targets; null for [] or legacy root without pom.xml. */
  /** lastRun is the most recent finished Maven run, independent of currentRun. */
  maven: null | { currentRun: TaskRunSummary | null; lastRun: TaskRunSummary | null };
  /** v1.3-D. v1.3 daemons always send it; optional for older ones. */
  policy?: ProjectPolicy;
}

// ───────────────────────── Resources ─────────────────────────

export type SampleStatus =
  | 'sampling' // not enough samples yet for CPU (first interval)
  | 'ok'
  | 'partial' // some processes could not be read
  | 'unavailable'; // nothing could be read

export interface ResourceSample {
  status: SampleStatus;
  sampledAt: Timestamp | null;
  /** Sum over tracked processes; 100 = one logical CPU. Not capped. Null unless status ok/partial. */
  cpuPercent: number | null;
  /** Sum of RSS over tracked processes (estimate; shared pages double-counted). */
  rssBytes: number | null;
  /** macOS physical footprint sum over all tracked processes, bytes. Null/absent if unsupported or any read failed; never a partial sum. */
  footprintBytes?: number | null;
  processCount: number | null;
  note?: string; // reason for partial / unavailable
}

export interface ServiceStats extends ResourceSample {
  runId: RunId;
  /**
   * v1.1-B. TCP LISTEN sockets of this run's verified processes only.
   * null = could not be read this cycle (or not read yet); [] = confirmed none.
   */
  listening: ListeningPort[] | null;
}

export interface ListeningPort {
  port: number;
  /** e.g. "127.0.0.1", "0.0.0.0", "::1", "::". */
  address: string;
  family: 'ipv4' | 'ipv6';
  /** 127.0.0.0/8 and ::1 → loopback; 0.0.0.0 and :: → all; anything else → other. */
  scope: 'loopback' | 'all' | 'other';
  /** The managed process holding the socket. */
  pid: number;
}

export interface ProjectStats {
  /** Deduplicated by process identity across services. */
  total: ResourceSample;
  /** Only services with a current run. */
  services: Record<ServiceId, ServiceStats>;
  /** v1.2-C. Only running task runs, keyed by run ID; also counted in total (deduplicated). */
  tasks: Record<RunId, ServiceStats>;
}

export interface StatsSnapshot {
  sampledAt: Timestamp;
  intervalMs: number;
  /** Only projects with at least one current run. */
  projects: Record<ProjectId, ProjectStats>;
}

// ───────────────────────── Operations ─────────────────────────

export type ActionKind = 'start' | 'stop' | 'restart' | 'force-stop';

export interface ActionRequest {
  projectId: ProjectId;
  /** Omitted = every service of the project (config order). */
  serviceIds?: ServiceId[];
  action: ActionKind;
  /** v1.3-D. cli only (ignored for ui): start/restart past a hold; never past a lock. */
  overrideHold?: boolean;
}

export type OperationState =
  | 'queued'
  | 'running'
  | 'succeeded' // every target reached the requested outcome
  | 'partial' // mixed outcomes
  | 'failed' // no target reached the requested outcome
  | 'cancelled'; // superseded by a later stop/force-stop

export type TargetOutcome =
  | 'pending'
  | 'started'
  | 'already-running'
  | 'stopped'
  | 'already-stopped'
  | 'stop-timeout' // graceful wait elapsed; process still alive
  | 'failed'
  | 'cancelled';

export interface OperationTargetResult {
  serviceId: ServiceId;
  outcome: TargetOutcome;
  runId: RunId | null; // run started / found / stopped
  /** For stop-timeout: STOP_TIMEOUT with details { timeoutSec: number, remaining: number }.
   * remaining counts still-live verified processes at timeout; timeoutSec is the actual wait limit in seconds.
   * Restart blocked by stop timeout uses outcome failed and retains the same error/details.
   */
  error: ApiError | null;
}

export interface Operation {
  id: OperationId;
  projectId: ProjectId;
  action: ActionKind;
  serviceIds: ServiceId[]; // resolved targets
  source: ClientKind | 'daemon';
  /** v1.3-C. source is always actor.client. v1.3 daemons always send it; optional for older ones. */
  actor?: Actor;
  state: OperationState;
  createdAt: Timestamp;
  finishedAt: Timestamp | null;
  results: OperationTargetResult[];
  cancelledBy: OperationId | null;
}

// ───────────────────────── Logs ─────────────────────────

/** 'sys' = lines the daemon inserts (spawned, signal sent, exited…). */
export type LogStream = 'out' | 'err' | 'sys';

export interface LogLine {
  /** Per-run, starts at 1, strictly increasing, never reused. */
  seq: number;
  ts: Timestamp; // collection time
  stream: LogStream;
  /** Raw text without trailing newline; may contain ANSI escape sequences. */
  text: string;
  /** Line was split because it exceeded logLineMaxBytes; the next seq continues it. */
  partial?: boolean;
}

export interface LogPage {
  runId: RunId;
  lines: LogLine[];
  firstSeq: number | null; // oldest retained in the run (not in this page)
  lastSeq: number | null; // newest available in the run
  truncated: boolean; // older content was dropped by limits
  hasMoreBefore: boolean;
  hasMoreAfter: boolean;
  runEnded: boolean;
}

/** v1.5-A: bounded literal search over retained logs, including lines outside the UI buffer. */
export interface LogSearchMatch {
  line: LogLine;
  before: LogLine[];
  after: LogLine[];
}
export interface LogSearchPage {
  runId: RunId;
  throughSeq: number;
  scannedThroughSeq: number;
  hasMore: boolean;
  truncated: boolean;
  matches: LogSearchMatch[];
}

/** v1.5-B: shareable file, applied explicitly through existing project routes. */
export interface PortableConfigInput {
  id: string;
  /** JSON Pointer into project; only documented scalar environment/param/command/cwd fields. */
  target: string;
  kind: 'secret' | 'path';
  label: string;
  valueType?: ParamType;
}
export interface PortableProjectConfig {
  format: 'devpanel.project';
  version: 1;
  project: Omit<ProjectConfig, 'root'>;
  inputs: PortableConfigInput[];
}

// ───────────────────────── Daemon ─────────────────────────

export interface Limits {
  logBytesPerRun: number;
  runsKeptPerService: number;
  logBytesGlobal: number;
  logLineMaxBytes: number;
  logPageMaxLines: number;
  statsIntervalMs: number;
  startGraceMs: number;
  defaultStopTimeoutSec: number;
  /** v1.2-C. Kept per quick action, and for Maven per project. Default 5. */
  taskRunsKept: number;
  /** v1.2-C. Default 16 MiB. */
  logBytesPerTaskRun: number;
  /** v1.3-C. Default 500. */
  activityKeptPerProject?: number;
}

/** DevPanel backend only, excluding all managed business processes. */
export interface DaemonToolResources {
  daemon: ResourceSample;
  helpers: ResourceSample;
  total: ResourceSample;
}

export interface DaemonInfo {
  version: string;
  apiVersion: typeof API_VERSION;
  pid: number;
  startedAt: Timestamp;
  home: string; // data directory
  limits: Limits;
  /** The daemon's own footprint (not managed services). */
  self: ResourceSample;
  toolResources?: DaemonToolResources;
}

// ───────────────────────── Validation ─────────────────────────

export interface ValidationIssue {
  /** JSON-path-ish location, e.g. "services[1].command[0]". */
  path: string;
  severity: 'error' | 'warning';
  code: ErrorCode | WarningCode;
  message: string;
}

export type WarningCode =
  | 'WARN_BACKGROUND_COMMAND' // "&", nohup, "-d" detach flags, etc.
  | 'WARN_SHELL_COMPOUND' // shell string with &&, ;, | — consider splitting services
  | 'WARN_SECRET_LIKE_PLAIN' // secret-like env name stored plain, except a value composed only of secret param references
  | 'WARN_PARAM_UNUSED'; // v1.1-A: param defined but referenced nowhere

export interface ServiceResolution {
  serviceId: ServiceId;
  cwdAbs: string;
  cwdExists: boolean;
  program: string; // command[0] as given
  /** Null when unresolved, including a masked PATH in standalone validation (no COMMAND_NOT_FOUND in that case). */
  programResolved: string | null; // absolute path, null if not found
  /** Empty when the effective PATH is an unresolved secret placeholder in standalone validation. */
  pathUsed: string; // effective PATH used for lookup
}

/** Standalone validation accepts {secret:true} without value; register/update additionally check stored secret keys. */
export interface ValidateResult {
  ok: boolean; // no error-severity issues
  issues: ValidationIssue[];
  services: ServiceResolution[];
}

// ───────────────────────── Requests / responses ─────────────────────────

/** Existing-root comparison ignores param response metadata; incompatible protected user
 * values use incoming values for comparison (usually 409 CONFIG_CONFLICT), never save them. */
export type RegisterRequest = ProjectConfig;
export interface RegisterResponse {
  created: boolean; // false = identical config already registered at this root
  project: Project;
}

export interface UpdateRequest {
  ifRevision: number;
  config: ProjectConfig;
  /**
   * v1.1-A. By default a param whose stored setBy is 'user' keeps its stored value even if the
   * request carries a different one; true lets the request overwrite those values.
   * An incompatible protected value returns 422 CONFIG_INVALID / PARAM_INVALID with an override hint.
   */
  overrideUserValues?: boolean;
}

/** v1.1-A. PUT /projects/:id response. keptUserValues lists param keys whose user-set value was preserved. */
export type UpdateResponse = Project & { keptUserValues?: string[] };

/** v1.1-A. POST /projects/:id/params. Param routes validate params only, not cwd/program
 * availability. Invalid values: 422 CONFIG_INVALID with PARAM_INVALID issues.
 * PATCH/DELETE unknown key: 404 PARAM_UNKNOWN. DELETE requires ifRevision (missing: 400
 * BAD_REQUEST), defaults inline to false, and obeys the same param-only validation. */
export interface AddParamRequest {
  ifRevision: number;
  param: ParamConfig;
}

/** v1.1-A. PATCH /projects/:id/params/:key — only the fields present are changed. */
export interface PatchParamRequest {
  ifRevision: number;
  value?: ParamValue;
  label?: string;
  description?: string;
  choices?: ParamChoice[];
  min?: number;
  max?: number;
}

/** Shutdown stops bypass supervision rules, preserve existing holds/locks, and record the requesting actor. */
export interface ShutdownRequest {
  /** Must be true if anything is running, otherwise the request fails with PROJECT_RUNNING. */
  stopServices: boolean;
}

export interface ConfigDiffEntry {
  path: string;
  existing: unknown;
  incoming: unknown;
}

// ───────────────────────── Errors ─────────────────────────

export type ErrorCode =
  | 'PROJECT_NOT_FOUND'
  | 'SERVICE_NOT_FOUND'
  | 'RUN_NOT_FOUND'
  | 'OPERATION_NOT_FOUND'
  | 'CONFIG_INVALID'
  | 'CONFIG_CONFLICT' // root already registered with a different config
  | 'REVISION_MISMATCH'
  | 'COMMAND_NOT_FOUND'
  | 'CWD_UNAVAILABLE'
  | 'SPAWN_FAILED'
  | 'EXITED_DURING_START'
  | 'STOP_TIMEOUT'
  | 'STATE_UNVERIFIABLE'
  | 'PROJECT_RUNNING'
  | 'OPERATION_CANCELLED'
  | 'UNAUTHORIZED'
  | 'FORBIDDEN_ORIGIN'
  | 'BAD_REQUEST'
  | 'DAEMON_UNREACHABLE' // produced by clients, never by the daemon
  | 'PARAM_UNKNOWN' // v1.1-A: ${key} references no param
  | 'PARAM_INVALID' // v1.1-A: bad key, type, choice, or out of min/max
  | 'PARAM_IN_USE' // v1.1-A: delete refused (referenced and not inlined, or secret referenced by a command)
  | 'ACTION_NOT_FOUND' // v1.2-C
  | 'TASK_RUNNING' // v1.2-C: the action / project Maven slot is busy, or delete refused while running
  | 'MAVEN_UNAVAILABLE' // v1.2-C: no pom.xml at the project root
  | 'MAVEN_INVALID' // v1.2-C: bad module, goal or profile
  | 'GIT_UNAVAILABLE' // v1.2-D: git not found
  | 'GIT_LOCKED' // v1.2-D: index.lock present
  | 'GIT_HEAD_MOVED' // v1.2-D: commit expectedHead differs from HEAD
  | 'GIT_HOOK_FAILED' // v1.2-D
  | 'GIT_CONFLICT' // v1.2-D: stash apply conflicted
  | 'GIT_FAILED' // v1.2-D: any other git error
  | 'FORBIDDEN_CLIENT' // v1.2-D: Git writes only accept X-DevPanel-Client: ui (v1.3-D: also policy writes)
  | 'POLICY_DENIED' // v1.3-D: details { reason: 'hold' | 'locked' | 'force-stop', serviceId }
  | 'INTERNAL';

export interface ApiError {
  code: ErrorCode;
  message: string;
  details?: Record<string, unknown>;
}

export interface ErrorBody {
  error: ApiError;
}

// ───────────────────────── Event streams (SSE) ─────────────────────────

/** GET /api/v1/events — SSE `event:` name equals `type`, `data:` is the JSON object. */
export type DaemonEvent =
  | { type: 'snapshot'; daemon: DaemonInfo; projects: ProjectView[]; operations: Operation[]; stats: StatsSnapshot | null }
  | { type: 'project.upsert'; project: ProjectView }
  | { type: 'project.remove'; projectId: ProjectId }
  | { type: 'operation'; operation: Operation }
  | { type: 'stats'; stats: StatsSnapshot }
  | { type: 'ping'; at: Timestamp };

/** GET /api/v1/runs/:runId/logs/stream?afterSeq=N */
export type LogStreamEvent =
  | { type: 'lines'; runId: RunId; lines: LogLine[] }
  | { type: 'truncated'; runId: RunId; firstSeq: number }
  | { type: 'gap'; runId: RunId; afterSeq: number; reason: string }
  | { type: 'end'; runId: RunId; run: RunSummary | TaskRunSummary }
  | { type: 'ping'; at: Timestamp };

// ───────────────────────── Local discovery ─────────────────────────

/** Written by the daemon to <home>/daemon.json with mode 0600. */
export interface DaemonDiscovery {
  pid: number;
  version: string;
  apiVersion: typeof API_VERSION;
  socketPath: string; // unix socket (CLI)
  httpPort: number; // 127.0.0.1 only (UI)
  token: string; // bearer token for HTTP
  startedAt: Timestamp;
}

// ───────────────────────── Quick actions & Maven (v1.2-C) ─────────────────────────

/** Same format as ServiceId; unique within the project, separate namespace from services. */
export type ActionId = string;

/** An AI-defined, run-to-completion command shown as a one-click button. */
export interface ActionConfig {
  id: ActionId;
  /** Button text, e.g. "clean install -DskipTests". */
  name: string;
  description?: string;
  cwd: string;
  /** argv; ${key} params are substituted at run time (api.md §3.1). */
  command: string[];
  env?: EnvMap;
  /** Wait after cancel before reporting cancelTimedOut. Default 10, 1–300. */
  stopTimeoutSec?: number;
  /** Max run time; absent = unlimited. 1–86400. */
  timeoutSec?: number;
  /** Client asks for confirmation when any service of the project is running; the daemon does not block. */
  confirmWhenServicesRunning?: boolean;
}

export const MAVEN_PHASES = ['clean', 'validate', 'compile', 'test', 'package', 'verify', 'install', 'site', 'deploy'] as const;
export type MavenPhase = (typeof MAVEN_PHASES)[number];

/** One pom.xml, parsed statically (no Maven run, no network, no ~/.m2). */
export interface MavenModule {
  /** Module directory relative to the project root; "." for the root. Also the -pl value. */
  id: string;
  pomPath: string;
  /** The module that aggregates this one through <modules>. */
  parentId: string | null;
  /** From this POM or its <parent>. */
  groupId: string | null;
  artifactId: string;
  name: string | null;
  /** Default "jar". */
  packaging: string;
  /** Profile ids declared in this POM. */
  profiles: string[];
  /** <parent> points at a POM that is not inside the project. */
  parentOutside: boolean;
  /** Why this POM could not be parsed; other fields are best effort. */
  error: string | null;
}

export interface MavenModel {
  /** What a run will actually use. */
  executable: 'wrapper' | 'mvn';
  /** Root first, then depth-first in <modules> order. */
  modules: MavenModule[];
  /** All declared profile ids, de-duplicated. */
  profiles: string[];
  scannedAt: Timestamp;
}

/** The daemon builds `<mvnw|mvn> [-pl id [-am]] [-DskipTests] [-o] [-P a,!b] goals...` from this; no free-form args. */
export interface MavenRunRequest {
  /** v1.4-A. Required when multiple Maven targets are registered. */
  mavenProjectId?: string;
  moduleId: string;
  /** Phases or plugin goals, passed in this order. Each matches ^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+){0,3}(@[A-Za-z0-9_.-]+)?$ */
  /** Nonempty; each goal matches api.md §11.3 and must not start with "-". Unknown request fields are rejected. */
  goals: string[];
  /** "id" activates, "!id" deactivates. Each matches ^!?[A-Za-z0-9_.-]+$ */
  profiles?: string[];
  skipTests?: boolean;
  offline?: boolean;
  /** -am; only meaningful when moduleId is not ".". */
  alsoMake?: boolean;
}

export type TaskRunKind = 'action' | 'maven';
export type TaskRunState =
  | 'running'
  | 'cancelling' // SIGTERM sent, waiting for exit
  | 'succeeded' // ended on its own with exit code 0
  | 'failed' // ended on its own with non-zero / signal, or could not start
  | 'cancelled'
  | 'timed-out'
  | 'unknown'; // after a daemon restart, ownership could not be verified

/** A run of a quick action or of Maven. Shares the RunId namespace, so /runs/:runId/logs works for it. */
export interface TaskRunSummary {
  id: RunId;
  projectId: ProjectId;
  kind: TaskRunKind;
  actionId: ActionId | null;
  maven: MavenRunRequest | null;
  /** For display, e.g. "clean install · backend". */
  label: string;
  configRevision: number;
  source: ClientKind;
  /** v1.3-C. v1.3 daemons always send it; optional for older ones. */
  startedBy?: Actor | null;
  startedAt: Timestamp;
  endedAt: Timestamp | null;
  pid: number | null;
  state: TaskRunState;
  exit: ExitInfo | null;
  /** cancelling for longer than stopTimeoutSec. */
  cancelTimedOut: boolean;
}

export interface TaskRunDetail extends TaskRunSummary {
  /** argv actually executed; fragments from secret params are "••••". */
  command: string[];
  cwd: string;
  envKeys: string[];
  params: Record<string, ParamValue | { secret: true }>;
  log: LogInfo;
  processes: ProcessInfo[];
}

export interface ActionView {
  id: ActionId;
  name: string;
  description: string | null;
  confirmWhenServicesRunning: boolean;
  currentRun: TaskRunSummary | null;
  /** Most recent finished run; currentRun is independent. */
  lastRun: TaskRunSummary | null;
}

/** POST /projects/:id/actions/:actionId/runs and POST /projects/:id/maven/runs */
export interface StartTaskRunResponse {
  /** false = the action was already running; run is that run (Maven never returns false: a busy slot is 409). */
  created: boolean;
  run: TaskRunSummary;
}

/** POST /task-runs/:runId/cancel */
export interface CancelTaskRunRequest {
  force?: boolean;
}

// ───────────────────────── Git (v1.2-D) ─────────────────────────

export type GitChange = 'modified' | 'added' | 'deleted' | 'renamed' | 'copied' | 'typechange' | 'unmerged';

export interface GitEntry {
  /** Relative to the repository root, "/" separated. */
  path: string;
  origPath: string | null;
  /** Staged change. */
  index: GitChange | null;
  /** Unstaged change. */
  worktree: GitChange | null;
  untracked: boolean;
  conflicted: boolean;
  /** File name matches the sensitive patterns in api.md §12; a hint only. */
  sensitiveName: boolean;
}

export interface GitStatus {
  /** null = the project root is not inside a Git work tree. */
  repo: null | {
    root: string;
    /** null when HEAD is detached. */
    branch: string | null;
    /** null in an empty repository. */
    headSha: string | null;
    upstream: string | null;
    ahead: number;
    behind: number;
  };
  entries: GitEntry[];
  /** More than 5,000 entries. */
  truncated: boolean;
  checkedAt: Timestamp;
}

export interface GitDiffLine {
  kind: 'context' | 'add' | 'del' | 'meta';
  text: string;
  oldNo: number | null;
  newNo: number | null;
}

export interface GitDiff {
  /** Git blob object IDs; null when that side is absent or unmerged. Worktree hashes raw bytes without writing objects. */
  baseOid: string | null;
  newOid: string | null;
  path: string;
  staged: boolean;
  binary: boolean;
  /** Bytes; for the binary-file hint. */
  oldSize: number | null;
  newSize: number | null;
  /** More than 5,000 lines or 2 MiB. */
  truncated: boolean;
  additions: number;
  deletions: number;
  hunks: { header: string; lines: GitDiffLine[] }[];
}

export interface GitStash {
  /** e.g. "stash@{0}" */
  ref: string;
  message: string;
  branch: string | null;
  createdAt: Timestamp;
}

export interface GitPathsRequest {
  paths: string[];
}

export interface GitCommitRequest {
  message: string;
  amend?: boolean;
  /** HEAD the user looked at; a different HEAD → 409 GIT_HEAD_MOVED. null for an empty repository. */
  expectedHead: string | null;
}

export interface GitCommitResult {
  sha: string;
  /** Hook and git output. */
  output: string;
}

export interface GitStashRequest {
  message?: string;
  includeUntracked?: boolean;
}

export interface GitStashApplyRequest {
  ref: string;
  /** true = pop. A conflicted apply keeps the stash even when true. */
  drop: boolean;
}

// ───────────────────────── Readiness report (v1.3-A) ─────────────────────────

/** stdout of `devpanel start|restart --wait-ready --json`, on success and failure alike (api.md §13). */
export interface CliStartReport {
  operation: Operation;
  services: {
    serviceId: ServiceId;
    runId: RunId | null;
    outcome: TargetOutcome;
    /** null when there is no run. */
    ready: ReadyInfo | null;
    /** Real ports when the report was made. */
    listening: ListeningPort[] | null;
    /** Only for ended-before-ready, timed-out or failed targets. */
    digest: LogDigest | null;
  }[];
}

// ───────────────────────── Log digest (v1.3-B) ─────────────────────────

/** GET /runs/:runId/digest — deterministic compression, no diagnosis (api.md §14). */
export interface DigestLine {
  seq: number;
  stream: LogStream;
  /** ANSI stripped; longer than 1 KiB is cut and ends with "…". */
  text: string;
  /** Consecutive identical lines including this one; present when ≥ 2. */
  repeat?: number;
  /** Stack lines folded after this line. */
  folded?: { lines: number; lastSeq: number };
}

export interface LogDigestBlock {
  kind: 'error' | 'tail';
  firstSeq: number;
  lastSeq: number;
  /** error: blocks with the same signature (≥ 1); tail: 1. */
  occurrences: number;
  /** error: headline seq of the last occurrence. */
  lastOccurrenceSeq: number;
  lines: DigestLine[];
}

export interface LogDigest {
  runId: RunId;
  afterSeq: number | null;
  lastSeq: number | null;
  scannedLines: number;
  /** Distinct error blocks after signature de-duplication. */
  errorBlocks: number;
  /** Error blocks by first occurrence, tail last. */
  blocks: LogDigestBlock[];
  omitted: { errorBlocks: number; bytes: number };
  /** Content before or inside the range was dropped by log limits. */
  truncated: boolean;
  runEnded: boolean;
}

// ───────────────────────── Activity (v1.3-C) ─────────────────────────

export type ActivityDetail =
  | {
      kind: 'operation';
      operationId: OperationId;
      action: ActionKind;
      serviceIds: ServiceId[];
      state: OperationState;
      results: { serviceId: ServiceId; outcome: TargetOutcome; runId: RunId | null; errorCode: ErrorCode | null }[];
      /** v1.3-D. The cli request passed overrideHold and it released a hold. */
      overrideHold?: boolean;
    }
  | {
      kind: 'config';
      change: 'register' | 'update' | 'param';
      /** 0 for register. */
      fromRevision: number;
      toRevision: number;
      /** At most 100; secret values are always { secret: true }. */
      changes: ConfigDiffEntry[];
      changesTruncated: boolean;
    }
  | { kind: 'task-run'; runId: RunId; taskKind: TaskRunKind; label: string; state: TaskRunState }
  | { kind: 'policy'; serviceId: ServiceId | null; change: 'hold' | 'release' | 'lock' | 'unlock' | 'settings' };

export interface ActivityEntry {
  /** "a_" + ULID. */
  id: string;
  projectId: ProjectId;
  at: Timestamp;
  actor: Actor;
  detail: ActivityDetail;
}

/** GET /projects/:id/activity?before=&limit= — newest first. */
export interface ActivityPage {
  entries: ActivityEntry[];
  hasMore: boolean;
}

// ───────────────────────── Policy (v1.3-D) ─────────────────────────

/**
 * Constrains cli requests on services only; ui requests are never constrained. Not part of
 * ProjectConfig: only PUT /projects/:id/policy from a ui client changes it. Guards against
 * mistakes, not a security boundary (api.md §16).
 */
export interface ProjectPolicy {
  /** Default true. */
  holdAfterUserStop: boolean;
  /** Default 'deny'. */
  agentForceStop: 'allow' | 'deny';
  /** Default []. */
  lockedServices: ServiceId[];
}

export interface ServiceHold {
  since: Timestamp;
  /** The ui stop operation that created the hold. */
  operationId: OperationId;
}
