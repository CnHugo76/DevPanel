import path from 'node:path';
import { noReady, readySnapshot, logEvidence, portEvidence, type ReadyTracking } from "./ready.ts";
/**
 * In-memory model of the daemon: projects, services, runs, operations, logs and stats.
 * Processes are simulated (no real commands are executed), but the state machine and
 * operation semantics follow contract/api.md §3–§7.
 */
import type {
  MavenModel,
  MavenRunRequest,
  ActionConfig,
  TaskRunDetail,
  TaskRunSummary,
  StartTaskRunResponse,
  ActionKind,
  ActionRequest,
  ApiError,
  ClientKind,
  ConfigDiffEntry, Actor,
  DaemonEvent,
  DaemonInfo,
  EnvMap,
  ExitInfo,
  ExitReason,
  Limits,
  ListeningPort,
  LogLine,
  LogPage,
  LogStream,
  LogStreamEvent,
  Operation,
  OperationTargetResult,
  ParamConfig,
  ParamValue,
  ProcessInfo,
  Project,
  ProjectAggregate,
  ProjectConfig,
  ProjectStats,
  ProjectView,
  RegisterResponse,
  ResourceSample,
  RunDetail,
  RunSummary,
  ServiceConfig,
  ServiceState,
  ServiceStats,
  ServiceView,
  StatsSnapshot,
  TargetOutcome,
  UpdateRequest,
  UpdateResponse,
  ValidateResult,
} from '@devpanel/contract';
import { MockGit } from './git.ts';
import { mavenCommand, mavenOutput, validateMavenRun } from './maven.ts';
import { HttpError, badRequest, notFound } from './errors.ts';
import {
  type Emit,
  type SimCtx,
  type SimProfile,
  baseline,
  deriveCtx,
  floodLine,
  inferProfile,
  listenPlan,
  processesFor,
  springPortConflict,
  startupLines,
  tickInterval,
  tickLines,
  termLines,
} from './sim.ts';
import {
  MASK,
  inlineParam,
  mergeParams,
  publicParams,
  setterOf,
  stripResponseOnly,
  substituteService,
  usedByMap,
} from './params.ts';
import { formatDuration, iso, newOperationId, newProjectId, newRunId, rand, randInt, sleep, stableStringify } from './util.ts';
import { normalizeRoot, resolveService, validateConfig } from './validate.ts';

import { Policies } from './policy.ts';
import { Activities, daemonActor, configDiff } from './activity.ts';

export const DEFAULT_LIMITS: Limits = {
  activityKeptPerProject: 500,
  taskRunsKept: 5,
  logBytesPerTaskRun: 16 * 1024 * 1024,
  logBytesPerRun: 32 * 1024 * 1024,
  runsKeptPerService: 3,
  logBytesGlobal: 1024 * 1024 * 1024,
  logLineMaxBytes: 64 * 1024,
  logPageMaxLines: 2000,
  statsIntervalMs: 2000,
  startGraceMs: 1000,
  defaultStopTimeoutSec: 10,
};

// ───────────────────────── internal records ─────────────────────────

export interface LogSubscriber {
  send(ev: LogStreamEvent): void;
  close(): void;
  /** Bytes buffered in the socket and not yet sent. */
  backlog(): number;
  lastSentSeq: number;
  pending: LogLine[];
  timer: NodeJS.Timeout | null;
}

interface RunRec {
  requestedBy?: Actor | null;
  readiness?: ReadyTracking;
  summary: RunSummary;
  /** Substituted argv with secret fragments masked (RunDetail.command). */
  command: string[];
  cwd: string;
  envKeys: string[];
  /** RunDetail.params. */
  params: Record<string, ParamValue | { secret: true }>;
  /** Effective (substituted) config this run started with (for configChangedSinceStart). */
  configSnapshot: string;
  /** Simulated LISTEN sockets once the server is up. */
  listen: ListeningPort[];
  listenAfterMs: number;
  lines: LogLine[];
  nextSeq: number;
  bytes: number;
  truncated: boolean;
  processes: ProcessInfo[];
  subscribers: Set<LogSubscriber>;
  timers: Set<NodeJS.Timeout>;
  profile: SimProfile;
  ctx: SimCtx;
  sampleCount: number;
  endedPromise: Promise<void>;
  resolveEnded: () => void;
  stopRequestedWhileStarting: boolean;
  terminating: boolean;
}

interface Task {
  opRec: OpRec;
  serviceId: string;
  action: ActionKind;
  cancelled: boolean;
  overrideHold?: boolean;
  bypassPolicy?: boolean;
  cancelPromise: Promise<void>;
  cancel: () => void;
}

interface OpRec {
  op: Operation;
  waiters: Set<() => void>;
}

interface SvcRt {
  id: string;
  state: ServiceState;
  stateSince: string | null;
  currentRunId: string | null;
  /** Oldest → newest. */
  runs: RunRec[];
  stopTimedOut: boolean;
  error: ApiError | null;
  queue: Task[];
  active: Task | null;
  forceActive: Task | null;
  profileOverride: SimProfile | null;
}

interface ProjRec {
  project: Project; // config holds secret values (masked on output)
  services: Map<string, SvcRt>;
}

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function maskEnv(env: EnvMap | undefined): EnvMap | undefined {
  if (!env) return env;
  const out: EnvMap = {};
  for (const [k, v] of Object.entries(env)) out[k] = typeof v === 'string' ? v : { secret: true };
  return out;
}

/** Response form: secret env / param values removed, params carry usedBy. */
export function maskConfig(cfg: ProjectConfig): ProjectConfig {
  const out: ProjectConfig = { ...cfg };
  if (cfg.env) out.env = maskEnv(cfg.env)!;
  out.services = cfg.services.map((s) => {
    const m: ServiceConfig = { ...s, command: [...s.command] };
    if (s.env) m.env = maskEnv(s.env)!;
    return m;
  });
  if (cfg.actions) out.actions = cfg.actions.map((a) => ({ ...a, command: [...a.command], ...(a.env ? { env: maskEnv(a.env) } : {}) }));
  const params = publicParams(cfg);
  if (params) out.params = params;
  return out;
}

/**
 * Comparison form: param bookkeeping (setBy, valueUpdatedAt, describedBy, usedBy) dropped.
 * masked=true also drops secret values (register idempotency ignores them, like secret env "keep" markers).
 */
function canonicalConfig(cfg: ProjectConfig, masked: boolean): ProjectConfig {
  const out: ProjectConfig = masked ? maskConfig({ ...cfg, params: undefined }) : { ...cfg };
  if (masked && cfg.env) out.env = maskEnv(cfg.env)!;
  if (cfg.params) {
    out.params = cfg.params.map((p) => {
      const o = stripResponseOnly(p);
      if (masked && o.secret) delete o.value;
      return o;
    });
  } else delete out.params;
  return out;
}

function secretParamKeys(cfg: ProjectConfig): Set<string> {
  return new Set((cfg.params ?? []).filter((p) => p.secret && p.value !== undefined).map((p) => p.key));
}

/** Params with some values replaced (seeding runs that started before a value was changed). */
function withParamValues(cfg: ProjectConfig, values: Record<string, ParamValue> | undefined): ProjectConfig {
  if (!values || !cfg.params) return cfg;
  return { ...cfg, params: cfg.params.map((p) => (p.key in values ? { ...p, value: values[p.key]! } : p)) };
}

function utf8Len(s: string): number {
  return Buffer.byteLength(s, 'utf8');
}

const DESIRED: Record<ActionKind, TargetOutcome[]> = {
  start: ['started', 'already-running'],
  restart: ['started'],
  stop: ['stopped', 'already-stopped'],
  'force-stop': ['stopped', 'already-stopped'],
};

// ───────────────────────── Engine ─────────────────────────

export class Engine {
  activity = new Activities();
  policies = new Policies(this.activity);

  limits: Limits;
  startedAt = Date.now();
  home: string;
  version = '0.1.0-mock';
  projects: ProjRec[] = [];
  operations = new Map<string, OpRec>();
  listeners = new Set<(e: DaemonEvent) => void>();
  lastStats: StatsSnapshot | null = null;
  /** Simulation knobs (tests turn the random listening-read failure off and shorten the delay). */
  sim: { listenFailRate: number; listenDelayMs: number | null; resourceFailRate: number } = { listenFailRate: 0.03, listenDelayMs: null, resourceFailRate: 0.07 };
  private gitRepos = new Map<string, MockGit>();
  private mavenModels = new Map<string, MavenModel>();
  private taskRuns = new Map<string, { p: ProjRec; cfg: ActionConfig; r: RunRec; summary: TaskRunSummary; timedOut?: boolean }>();
  taskSimulation = { durationMs: 3500, cancelDelayMs: 200, hangOnCancel: false };
  private readyTimer: NodeJS.Timeout | null = null;
  private statsTimer: NodeJS.Timeout | null = null;
  private selfSample: ResourceSample = { status: 'sampling', sampledAt: null, cpuPercent: null, rssBytes: null, footprintBytes: null, processCount: 1 };

  constructor(home: string, limits: Limits = DEFAULT_LIMITS) {
    this.home = home;
    this.limits = { ...limits, activityKeptPerProject: limits.activityKeptPerProject ?? 500 };
  }

  start(): void {
    this.readyTimer = setInterval(() => this.updateReady(), 250);
    this.statsTimer = setInterval(() => this.sampleAll(), this.limits.statsIntervalMs);
  }
  stop(): void {
    if (this.readyTimer) clearInterval(this.readyTimer);
    if (this.statsTimer) clearInterval(this.statsTimer);
    for (const t of this.taskRuns.values()) this.dropRun(t.r);
    for (const p of this.projects) for (const s of p.services.values()) for (const r of s.runs) this.clearTimers(r);
  }

  // ───────────── events ─────────────

  emit(e: DaemonEvent): void {
    for (const l of this.listeners) l(e);
  }
  private upsert(p: ProjRec): void {
    this.emit({ type: 'project.upsert', project: this.view(p) });
  }
  snapshot(): DaemonEvent {
    const cutoff = Date.now() - 10 * 60_000;
    const ops = [...this.operations.values()]
      .map((o) => o.op)
      .filter((o) => !o.finishedAt || Date.parse(o.finishedAt) > cutoff)
      .map((o) => structuredClone(o));
    return {
      type: 'snapshot',
      daemon: this.daemonInfo(),
      projects: this.projects.map((p) => this.view(p)),
      operations: ops,
      stats: this.lastStats,
    };
  }

  daemonInfo(): DaemonInfo {
    // Entirely simulated tool samples, never label this Node process's RSS as footprint.
    const helpers: ResourceSample = {
      status: this.selfSample.status, sampledAt: this.selfSample.sampledAt,
      cpuPercent: this.selfSample.cpuPercent === null ? null : 0.2,
      rssBytes: this.selfSample.rssBytes === null ? null : 2 * 1024 ** 2,
      footprintBytes: this.selfSample.footprintBytes == null ? null : 1024 ** 2,
      processCount: 1, note: 'mock 模拟辅助进程',
    };
    return {
      version: this.version,
      apiVersion: 1,
      pid: process.pid,
      startedAt: iso(this.startedAt),
      home: this.home,
      limits: this.limits,
      self: this.selfSample,
      toolResources: { daemon: this.selfSample, helpers, total: totalOf([this.selfSample, helpers], this.selfSample.sampledAt ? Date.parse(this.selfSample.sampledAt) : this.startedAt) },
    };
  }

  // ───────────── lookup ─────────────

  getProj(id: string): ProjRec {
    const p = this.projects.find((x) => x.project.id === id);
    if (!p) throw notFound('PROJECT_NOT_FOUND', `项目不存在：${id}`);
    return p;
  }
  private svcCfg(p: ProjRec, sid: string): ServiceConfig {
    const s = p.project.config.services.find((x) => x.id === sid);
    if (!s) throw notFound('SERVICE_NOT_FOUND', `服务不存在：${sid}`);
    return s;
  }
  private svcRt(p: ProjRec, sid: string): SvcRt {
    const s = p.services.get(sid);
    if (!s) throw notFound('SERVICE_NOT_FOUND', `服务不存在：${sid}`);
    return s;
  }
  findRun(runId: string): { p: ProjRec; s: SvcRt; r: RunRec } {
    for (const p of this.projects)
      for (const s of p.services.values())
        for (const r of s.runs) if (r.summary.id === runId) return { p, s, r };
    throw notFound('RUN_NOT_FOUND', `运行不存在或已被保留策略删除：${runId}`);
  }

  // ───────────── views ─────────────

  private currentRun(s: SvcRt): RunRec | null {
    if (!s.currentRunId) return null;
    return s.runs.find((r) => r.summary.id === s.currentRunId) ?? null;
  }

  private serviceView(p: ProjRec, cfg: ServiceConfig): ServiceView {
    const s = p.services.get(cfg.id)!;
    const cur = this.currentRun(s);
    const last = s.runs[s.runs.length - 1] ?? null;
    return {
      id: cfg.id,
      name: cfg.name,
      state: s.state,
      stateSince: s.stateSince,
      currentRun: cur ? { ...cur.summary } : null,
      lastRun: last ? { ...last.summary } : null,
      stopTimedOut: s.stopTimedOut,
      pendingOperationId: s.forceActive?.opRec.op.id ?? s.active?.opRec.op.id ?? s.queue[0]?.opRec.op.id ?? null,
      configChangedSinceStart: cur ? cur.configSnapshot !== this.effectiveSnapshot(p.project.config, cfg) : false,
      error: s.error,
      hold: this.policies.hold(p.project.id, cfg.id),
      locked: this.policies.get(p.project.id).lockedServices.includes(cfg.id),
    };
  }

  view(p: ProjRec): ProjectView {
    const services = p.project.config.services.map((c) => this.serviceView(p, c));
    return {
      id: p.project.id,
      name: p.project.config.name,
      instance: p.project.config.instance,
      root: p.project.config.root,
      revision: p.project.revision,
      policy: this.policies.get(p.project.id),
      aggregate: aggregate(services.map((s) => s.state)),
      runningCount: services.filter((s) => s.state === 'running').length,
      serviceCount: services.length,
      services,
      actions: (p.project.config.actions ?? []).map((a) => {
        const runs = this.actionRuns(p.project.id, a.id);
        return { id: a.id, name: a.name, description: a.description ?? null, confirmWhenServicesRunning: a.confirmWhenServicesRunning ?? false, currentRun: runs.find((r) => r.endedAt === null) ?? null, lastRun: runs.find(r => r.endedAt !== null) ?? null };
      }),
      repositories: p.project.config.repositories,
      mavenProjects: p.project.config.mavenProjects?.map(t => {
        const runs = this.mavenRuns(p.project.id, t.id);
        return { ...t, currentRun: runs.find(r => !r.endedAt) ?? null, lastRun: runs.find(r => r.endedAt) ?? null };
      }),
      maven: (p.project.config.mavenProjects === undefined ? this.mavenModels.has(p.project.id) : p.project.config.mavenProjects.length > 0) ? { currentRun: this.mavenRuns(p.project.id).find(r => !r.endedAt) ?? null, lastRun: this.mavenRuns(p.project.id).find(r => r.endedAt !== null) ?? null } : null,
    };
  }

  maskedProject(p: ProjRec): Project {
    return { ...p.project, config: maskConfig(p.project.config) };
  }

  actor(actor: Actor, extra?: ProjectConfig): Actor {
    if (actor.client !== 'cli') return { client: actor.client, agent: actor.agent };
    const secrets = [...this.projects.map(p => p.project.config), ...(extra ? [extra] : [])].flatMap(c => [
      ...(c.params ?? []).flatMap(p => p.secret && p.value !== undefined ? [String(p.value)] : []),
      ...[c.env, ...[...c.services, ...(c.actions ?? [])].map(s => s.env)].flatMap(env => Object.values(env ?? {}).flatMap(v => typeof v === 'object' && v.value ? [v.value] : [])),
    ]).filter(Boolean).sort((a, b) => b.length - a.length);
    const pattern = secrets.length ? new RegExp([...new Set(secrets)].map(s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'g') : null;
    const clean = (value: string | undefined) => value === undefined ? undefined : pattern ? value.replace(pattern, '[REDACTED]') : value;
    return { client: actor.client, agent: actor.agent, ...(actor.taskId === undefined ? {} : { taskId: clean(actor.taskId) }), ...(actor.taskLabel === undefined ? {} : { taskLabel: clean(actor.taskLabel) }) };
  }

  /**
   * What would actually run: substituted argv + effective env (secrets compared privately),
   * resolved cwd and defaulted stop timeout. Service name and other services do not count.
   */
  private effectiveSnapshot(cfg: ProjectConfig, svc: ServiceConfig): string {
    const sub = substituteService(cfg, svc);
    const res = resolveService(cfg, svc);
    return stableStringify({
      command: sub.command,
      env: sub.env,
      cwd: res.cwdAbs,
      stopTimeoutSec: svc.stopTimeoutSec ?? this.limits.defaultStopTimeoutSec,
    });
  }

  // ───────────── config ─────────────

  validate(cfg: unknown): ValidateResult {
    return validateConfig(cfg);
  }

  private secretKeys(cfg: ProjectConfig): Set<string> {
    const keys = new Set<string>();
    for (const [k, v] of Object.entries(cfg.env ?? {})) if (typeof v !== 'string' && v.value !== undefined) keys.add(`env.${k}`);
    for (const s of cfg.services)
      for (const [k, v] of Object.entries(s.env ?? {})) if (typeof v !== 'string' && v.value !== undefined) keys.add(`svc:${s.id}.${k}`);
    for (const a of cfg.actions ?? []) for (const [k, v] of Object.entries(a.env ?? {})) if (typeof v !== 'string' && v.value !== undefined) keys.add(`action:${a.id}.${k}`);
    return keys;
  }

  private assertValid(cfg: unknown, existing: ProjectConfig | null): ProjectConfig {
    const res = validateConfig(cfg, {
      existingSecrets: existing ? this.secretKeys(existing) : new Set(),
      existingSecretParams: existing ? secretParamKeys(existing) : new Set(),
    });
    if (!res.ok) {
      throw new HttpError(422, 'CONFIG_INVALID', '配置校验未通过', { issues: res.issues });
    }
    return structuredClone(cfg as ProjectConfig);
  }

  /** Replace "keep" markers with stored values. */
  private mergeSecrets(incoming: ProjectConfig, existing: ProjectConfig | null): ProjectConfig {
    const keep = (env: EnvMap | undefined, old: EnvMap | undefined): EnvMap | undefined => {
      if (!env) return env;
      const out: EnvMap = {};
      for (const [k, v] of Object.entries(env)) {
        if (typeof v !== 'string' && v.value === undefined) {
          const o = old?.[k];
          out[k] = o && typeof o !== 'string' ? { secret: true, value: o.value ?? '' } : { secret: true, value: '' };
        } else out[k] = v;
      }
      return out;
    };
    const out: ProjectConfig = { ...incoming };
    const penv = keep(incoming.env, existing?.env);
    if (penv) out.env = penv;
    if (incoming.actions) out.actions = incoming.actions.map((a) => ({ ...a, ...(a.env ? { env: keep(a.env, existing?.actions?.find((old) => old.id === a.id)?.env) } : {}) }));
    out.services = incoming.services.map((s) => {
      const old = existing?.services.find((x) => x.id === s.id);
      const m: ServiceConfig = { ...s };
      const e = keep(s.env, old?.env);
      if (e) m.env = e;
      return m;
    });
    return out;
  }

  register(input: unknown, actor: Actor = { client: "cli", agent: null }): { status: number; body: RegisterResponse } {
    const client = actor.client === "ui" ? "ui" : "cli";
    if (!isObj(input)) throw badRequest('请求体必须是 ProjectConfig');
    const rootIn = typeof input.root === 'string' ? normalizeRoot(input.root) : input.root;
    const existing = typeof rootIn === 'string' ? this.projects.find((p) => p.project.config.root === rootIn) : undefined;
    const cfg = this.assertValid({ ...input, root: rootIn }, existing?.project.config ?? null);
    const setter = setterOf(client);
    const now = iso();
    if (existing) {
      // Re-registration compares against stored config, keeping values a user set (contract v1.1-A).
      const merged = this.mergeSecrets(cfg, existing.project.config);
      const { params } = mergeParams(cfg.params, existing.project.config.params, setter, { override: false, now, onIncompatible: 'incoming' });
      if (params) merged.params = params;
      else delete merged.params;
      const diff = configDiff(existing.project.config, merged);
      if (diff.length === 0) return { status: 200, body: { created: false, project: this.maskedProject(existing) } };
      throw new HttpError(409, 'CONFIG_CONFLICT', '该根目录已注册为另一份配置；如需修改请使用更新', {
        projectId: existing.project.id,
        revision: existing.project.revision,
        diff,
      });
    }
    const config = this.mergeSecrets(cfg, null);
    const { params } = mergeParams(cfg.params, undefined, setter, { override: false, now, onIncompatible: 'incoming' });
    if (params) config.params = params;
    const rec: ProjRec = {
      project: { id: newProjectId(), revision: 1, createdAt: now, updatedAt: now, config },
      services: new Map(),
    };
    for (const s of cfg.services) rec.services.set(s.id, this.newSvcRt(s.id));
    this.projects.push(rec);
    this.activity.config(rec.project.id, this.actor(actor, config), "register", 0, 1, {}, config);
    this.upsert(rec);
    return { status: 201, body: { created: true, project: this.maskedProject(rec) } };
  }

  update(id: string, body: unknown, actor: Actor = { client: "cli", agent: null }): UpdateResponse {
    const client = actor.client === "ui" ? "ui" : "cli";
    const p = this.getProj(id);
    if (!isObj(body) || typeof body.ifRevision !== 'number' || !isObj(body.config)) {
      throw badRequest('请求体必须是 { ifRevision, config }');
    }
    const req = body as unknown as UpdateRequest;
    if (req.ifRevision !== p.project.revision) {
      throw new HttpError(409, 'REVISION_MISMATCH', `配置已被修改（当前 revision ${p.project.revision}）`, {
        revision: p.project.revision,
      });
    }
    const rootIn = typeof req.config.root === 'string' ? normalizeRoot(req.config.root) : req.config.root;
    const cfg = this.assertValid({ ...req.config, root: rootIn }, p.project.config);
    const clash = this.projects.find((x) => x !== p && x.project.config.root === cfg.root);
    if (clash) {
      throw new HttpError(409, 'CONFIG_CONFLICT', '该根目录已被另一个项目使用', {
        projectId: clash.project.id,
        revision: clash.project.revision,
        diff: [],
      });
    }
    for (const t of this.taskRuns.values()) if (t.p === p && t.summary.kind === 'action' && !t.summary.endedAt && !(cfg.actions ?? []).some((a) => a.id === t.summary.actionId)) throw new HttpError(409, 'TASK_RUNNING', '快捷操作正在运行，不能删除', { runId: t.summary.id });
    const newIds = new Set(cfg.services.map((s) => s.id));
    for (const [sid, rt] of p.services) {
      if (!newIds.has(sid) && ['starting', 'running', 'stopping', 'unknown'].includes(rt.state)) {
        throw new HttpError(409, 'PROJECT_RUNNING', `服务 ${sid} 正在运行，不能删除；请先停止`, { serviceId: sid });
      }
    }
    const now = iso();
    const merged = this.mergeSecrets(cfg, p.project.config);
    const { params, kept } = mergeParams(cfg.params, p.project.config.params, setterOf(client), {
      override: req.overrideUserValues === true,
      now,
      onIncompatible: 'throw',
    });
    if (params) merged.params = params;
    else delete merged.params;
    const respond = (): UpdateResponse => {
      const out: UpdateResponse = this.maskedProject(p);
      if (kept.length) out.keptUserValues = kept;
      return out;
    };
    // Unmasked comparison so that changing only a secret value is saved.
    if (stableStringify(canonicalConfig(p.project.config, false)) === stableStringify(canonicalConfig(merged, false))) return respond();
    actor = this.actor(actor, merged);
    this.activity.config(id, actor, "update", p.project.revision, p.project.revision + 1, p.project.config, merged);
    p.project = { ...p.project, revision: p.project.revision + 1, updatedAt: now, config: merged };
    const next = new Map<string, SvcRt>();
    for (const s of merged.services) next.set(s.id, p.services.get(s.id) ?? this.newSvcRt(s.id));
    for (const [sid, rt] of p.services) if (!next.has(sid)) for (const r of rt.runs) this.dropRun(r);
    p.services = next;
    this.policies.prune(id, merged.services.map(s => s.id), actor);
    for (const [id, t] of this.taskRuns) if (t.p === p && t.summary.kind === 'action' && !(merged.actions ?? []).some((a) => a.id === t.summary.actionId)) { this.dropRun(t.r); this.taskRuns.delete(id); }
    this.upsert(p);
    return respond();
  }

  // ───────────── params (v1.1-A) ─────────────

  private checkRevision(p: ProjRec, ifRevision: unknown): void {
    if (typeof ifRevision !== 'number' || !Number.isInteger(ifRevision)) throw badRequest('缺少 ifRevision（整数）');
    if (ifRevision !== p.project.revision) {
      throw new HttpError(409, 'REVISION_MISMATCH', `配置已被修改（当前 revision ${p.project.revision}）`, { revision: p.project.revision });
    }
  }

  private findParam(p: ProjRec, key: string): ParamConfig {
    const found = p.project.config.params?.find((x) => x.key === key);
    if (!found) throw notFound('PARAM_UNKNOWN', `选项不存在：${key}`);
    return found;
  }

  /**
   * Save a param-only change. Only param-related errors block it (an unrelated problem such as a
   * missing program on PATH must not prevent a person from adjusting a value).
   */
  private saveParams(p: ProjRec, next: ProjectConfig, actor: Actor): Project {
    const res = validateConfig(next, { existingSecrets: this.secretKeys(next), existingSecretParams: secretParamKeys(next) });
    const errors = res.issues.filter((i) => i.severity === 'error' && (i.code.startsWith('PARAM_') || i.path.startsWith('params')));
    if (errors.length) throw new HttpError(422, 'CONFIG_INVALID', '选项校验未通过', { issues: errors });
    this.activity.config(p.project.id, this.actor(actor, next), "param", p.project.revision, p.project.revision + 1, p.project.config, next);
    p.project = { ...p.project, revision: p.project.revision + 1, updatedAt: iso(), config: next };
    this.upsert(p);
    return this.maskedProject(p);
  }

  /** POST /projects/:id/params */
  addParam(id: string, body: unknown, actor: Actor = { client: "ui", agent: null }): Project {
    const client = actor.client === "ui" ? "ui" : "cli";
    const p = this.getProj(id);
    if (!isObj(body) || !isObj(body.param)) throw badRequest('请求体必须是 { ifRevision, param }');
    this.checkRevision(p, body.ifRevision);
    const param = stripResponseOnly(body.param as unknown as ParamConfig);
    if (p.project.config.params?.some((x) => x.key === param.key)) {
      throw new HttpError(409, 'CONFIG_CONFLICT', `选项 ${String(param.key)} 已存在`, {
        projectId: p.project.id,
        revision: p.project.revision,
        key: param.key,
      });
    }
    const setter = setterOf(client);
    const added: ParamConfig = { ...structuredClone(param), setBy: setter, valueUpdatedAt: iso(), describedBy: setter };
    return this.saveParams(p, { ...p.project.config, params: [...(p.project.config.params ?? []), added] }, actor);
  }

  /** PATCH /projects/:id/params/:key — only fields present in the body change. */
  patchParam(id: string, key: string, body: unknown, actor: Actor = { client: "ui", agent: null }): Project {
    const client = actor.client === "ui" ? "ui" : "cli";
    const p = this.getProj(id);
    if (!isObj(body)) throw badRequest('请求体必须是 { ifRevision, value?, label?, description?, choices?, min?, max? }');
    this.checkRevision(p, body.ifRevision);
    const old = this.findParam(p, key);
    const next: ParamConfig = { ...old };
    const setter = setterOf(client);
    const now = iso();
    let changed = false;
    if ('value' in body && stableStringify(body.value) !== stableStringify(old.value)) {
      next.value = body.value as ParamValue;
      next.setBy = setter;
      next.valueUpdatedAt = now;
      changed = true;
    }
    let described = false;
    for (const f of ['label', 'description', 'choices', 'min', 'max'] as const) {
      if (!(f in body) || stableStringify(body[f]) === stableStringify(old[f])) continue;
      (next as unknown as Record<string, unknown>)[f] = structuredClone(body[f]);
      described = true;
    }
    if (described) next.describedBy = setter;
    if (!changed && !described) return this.maskedProject(p);
    const params = p.project.config.params!.map((x) => (x.key === key ? next : x));
    return this.saveParams(p, { ...p.project.config, params }, actor);
  }

  /** DELETE /projects/:id/params/:key?ifRevision=N&inline=true|false */
  deleteParam(id: string, key: string, q: { ifRevision: unknown; inline: boolean }, actor: Actor = { client: "ui", agent: null }): Project {
    const p = this.getProj(id);
    this.checkRevision(p, q.ifRevision);
    const param = this.findParam(p, key);
    const cfg = p.project.config;
    const usedBy = usedByMap(cfg).get(key) ?? [];
    let next: ProjectConfig;
    if (usedBy.length === 0) {
      next = { ...cfg, params: cfg.params!.filter((x) => x.key !== key) };
    } else if (!q.inline) {
      throw new HttpError(409, 'PARAM_IN_USE', `选项 ${key} 仍被 ${usedBy.length} 处引用；如需删除请选择写回当前值`, { usedBy });
    } else if (param.secret && usedBy.some((r) => r.where === 'command')) {
      throw new HttpError(409, 'PARAM_IN_USE', `敏感选项 ${key} 被启动命令引用，写回会把秘密写进命令，已拒绝`, { usedBy, reason: 'secret' });
    } else {
      next = inlineParam(cfg, key);
    }
    return this.saveParams(p, next, actor);
  }

  remove(id: string): void {
    const p = this.getProj(id);
    for (const t of this.taskRuns.values()) if (t.p === p && !t.summary.endedAt) throw new HttpError(409, 'TASK_RUNNING', '项目有任务正在运行', { runId: t.summary.id });
    for (const rt of p.services.values()) {
      if (['starting', 'running', 'stopping', 'unknown'].includes(rt.state)) {
        throw new HttpError(409, 'PROJECT_RUNNING', '项目有服务正在运行，请先停止再移除', { serviceId: rt.id });
      }
    }
    this.policies.remove(id);
    this.activity.entries = this.activity.entries.filter(e => e.projectId !== id);
    for (const rt of p.services.values()) for (const r of rt.runs) this.dropRun(r);
    for (const [rid, t] of this.taskRuns) if (t.p === p) { this.dropRun(t.r); this.taskRuns.delete(rid); }
    this.gitRepos.delete(id);
    this.mavenModels.delete(id);
    this.projects = this.projects.filter((x) => x !== p);
    this.emit({ type: 'project.remove', projectId: id });
  }

  private newSvcRt(id: string): SvcRt {
    return {
      id,
      state: 'idle',
      stateSince: null,
      currentRunId: null,
      runs: [],
      stopTimedOut: false,
      error: null,
      queue: [],
      active: null,
      forceActive: null,
      profileOverride: null,
    };
  }

  private target<T extends { id: string; path: string }>(list: T[] | undefined, id?: string): T | undefined {
    if (list === undefined && id === undefined) return undefined;
    const target = id === undefined && list?.length === 1 ? list[0] : list?.find(t => t.id === id);
    if (!target) throw new HttpError(400, 'BAD_REQUEST', '请明确选择已登记的目标 ID');
    return target;
  }
  git(projectId: string, repositoryId?: string): MockGit {
    const p = this.getProj(projectId);
    const target = this.target(p.project.config.repositories, repositoryId);
    const key = target ? projectId + '#' + target.id : projectId;
    let repo = this.gitRepos.get(key);
    if (!repo) { repo = new MockGit(target ? path.resolve(p.project.config.root, target.path) : p.project.config.root); this.gitRepos.set(key, repo); }
    return repo;
  }
  seedGit(projectId: string, repositoryId?: string): void { this.git(projectId, repositoryId).reset(); }

  // Tasks reuse service log buffering and timers, but have a separate completion state.
  findLogRun(id: string): RunRec { return this.taskRuns.get(id)?.r ?? this.findRun(id).r; }

  actionRuns(projectId: string, actionId: string): TaskRunSummary[] {
    const p = this.getProj(projectId);
    if (!p.project.config.actions?.some((a) => a.id === actionId)) throw notFound('ACTION_NOT_FOUND', `快捷操作不存在：${actionId}`);
    return [...this.taskRuns.values()].filter((t) => t.p === p && t.summary.actionId === actionId).map((t) => structuredClone(t.summary)).reverse();
  }

  taskDetail(id: string): TaskRunDetail {
    const t = this.taskRuns.get(id);
    if (!t) throw notFound('RUN_NOT_FOUND', `任务运行不存在：${id}`);
    const d = this.logRunDetail(id);
    return { ...structuredClone(t.summary), command: d.command, cwd: d.cwd, envKeys: d.envKeys, params: d.params, log: d.log, processes: d.processes };
  }

  startAction(projectId: string, actionId: string, actor: Actor = { client: "cli", agent: null }): StartTaskRunResponse {
    actor = this.actor(actor);
    const p = this.getProj(projectId);
    const cfg = p.project.config.actions?.find((a) => a.id === actionId);
    if (!cfg) throw notFound('ACTION_NOT_FOUND', `快捷操作不存在：${actionId}`);
    const active = this.actionRuns(projectId, actionId).find((r) => !r.endedAt);
    if (active) return { created: false, run: active };
    return this.startTask(p, cfg, { kind: 'action', actionId }, actor);
  }

  /** Explicit virtual model: never scans real user projects or reads ~/.m2. */
  seedMaven(projectId: string, model: MavenModel, mavenProjectId?: string): void {
    this.getProj(projectId);
    this.mavenModels.set(mavenProjectId ? projectId + "#" + mavenProjectId : projectId, structuredClone(model));
  }

  mavenModel(projectId: string, reload = false, mavenProjectId?: string): MavenModel {
    const p = this.getProj(projectId);
    const target = this.target(p.project.config.mavenProjects, mavenProjectId);
    const config = target ? { ...p.project.config, root: path.resolve(p.project.config.root, target.path), maven: { executable: target.executable } } : p.project.config;
    const model = this.mavenModels.get(target ? projectId + "#" + target.id : projectId);
    if (!model) throw notFound('MAVEN_UNAVAILABLE', '项目根没有 pom.xml');
    if (reload) model.scannedAt = iso();
    const executable = config.maven?.executable ?? 'auto';
    const out = structuredClone(model);
    const wrapper = { id: 'maven', name: 'Maven', cwd: '.', command: ['./mvnw'] };
    const sub = substituteService(config, wrapper);
    out.executable = executable === 'auto'
      ? resolveService(config, { ...wrapper, env: sub.env }).programResolved ? 'wrapper' : 'mvn'
      : executable;
    const cfg = { ...wrapper, command: [out.executable === 'wrapper' ? './mvnw' : 'mvn'], env: sub.env };
    if (!resolveService(config, cfg).programResolved) throw new HttpError(422, 'COMMAND_NOT_FOUND', '找不到 Maven 可执行文件');
    return out;
  }

  mavenRuns(projectId: string, mavenProjectId?: string): TaskRunSummary[] {
    const p = this.getProj(projectId);
    if (mavenProjectId !== undefined) this.target(p.project.config.mavenProjects, mavenProjectId);
    return [...this.taskRuns.values()].filter(t => t.p === p && t.summary.kind === 'maven' && (mavenProjectId === undefined || t.summary.maven?.mavenProjectId === mavenProjectId)).map(t => structuredClone(t.summary)).reverse();
  }

  startMaven(projectId: string, input: unknown, actor: Actor = { client: "cli", agent: null }): StartTaskRunResponse {
    actor = this.actor(actor);
    const p = this.getProj(projectId);
    const active = this.mavenRuns(projectId).find(r => !r.endedAt);
    if (active) throw new HttpError(409, 'TASK_RUNNING', '项目已有 Maven 运行，请等待或取消', { runId: active.id });
    const rawId = (input as { mavenProjectId?: unknown } | null)?.mavenProjectId;
    if (rawId !== undefined && typeof rawId !== 'string') throw new HttpError(422, 'MAVEN_INVALID', 'mavenProjectId 必须为字符串');
    const target = this.target(p.project.config.mavenProjects, rawId);
    const model = this.mavenModel(projectId, false, target?.id);
    const request = validateMavenRun(input, model);
    if (target) request.mavenProjectId = target.id;
    return this.startTask(p, { id: 'maven', name: `${target ? target.name + ' · ' : ''}${request.goals.join(' ')} · ${request.moduleId}`, cwd: target?.path ?? '.', command: mavenCommand(model, request) }, { kind: 'maven', request, model }, actor);
  }

  private startTask(p: ProjRec, cfg: ActionConfig, target: { kind: 'action'; actionId: string } | { kind: 'maven'; request: MavenRunRequest; model: MavenModel }, actor: Actor): StartTaskRunResponse {
    const source = actor.client === "ui" ? "ui" : "cli";
    const projectId = p.project.id;
    const actionId = target.kind === 'action' ? target.actionId : null;
    const maven = target.kind === 'maven' ? target.request : null;
    const model = target.kind === 'maven' ? target.model : null;
    const sub = substituteService(p.project.config, cfg);
    const res = resolveService(p.project.config, { ...cfg, command: sub.command, env: sub.env });
    if (!res.cwdExists) throw new HttpError(422, 'CWD_UNAVAILABLE', '工作目录不可用');
    if (!res.programResolved) throw new HttpError(422, 'COMMAND_NOT_FOUND', '找不到任务程序');
    const rt = this.newSvcRt(cfg.id);
    const r = this.makeRun(p, rt, { ...cfg, id: rt.id }, Date.now(), true);
    r.summary.state = 'running';
    r.summary.startedBy = actor;
    const summary: TaskRunSummary = { id: r.summary.id, projectId, kind: maven ? 'maven' : 'action', actionId, maven, label: cfg.name, configRevision: p.project.revision, source, startedBy: actor, startedAt: r.summary.startedAt, endedAt: null, pid: r.summary.pid, state: 'running', exit: null, cancelTimedOut: false };
    this.taskRuns.set(summary.id, { p, cfg: structuredClone(cfg), r, summary });
    const history = [...this.taskRuns.values()].filter(t => t.p === p && t.summary.kind === summary.kind && t.summary.actionId === actionId);
    while (history.length > this.limits.taskRunsKept) { const old = history.shift()!; this.dropRun(old.r); this.taskRuns.delete(old.summary.id); }
    this.sys(r, `开始任务 · ${displayArgv(r.command)}`);
    const output = maven && model ? mavenOutput(model, maven) : { lines: ['[INFO] 正在执行快捷操作…', actionId === 'fail-demo' ? '[ERROR] 模拟构建失败' : '[INFO] BUILD SUCCESS'], failed: actionId === 'fail-demo' };
    output.lines.forEach((line, index) => this.later(r, Math.floor(this.taskSimulation.durationMs * (index + 1) / (output.lines.length + 1)), () => {
      if (summary.state !== 'cancelling') this.appendLog(r, line.startsWith('[ERROR]') ? 'err' : 'out', line);
    }));
    this.later(r, this.taskSimulation.durationMs, () => {
      if (summary.state === 'cancelling') return;
      this.finishTask(summary.id, output.failed ? 'failed' : 'succeeded', 'self-exit', output.failed ? 1 : 0, null);
    });
    if (cfg.timeoutSec) this.later(r, cfg.timeoutSec * 1000, () => this.cancelTask(summary.id, false, true));
    this.upsert(p);
    return { created: true, run: structuredClone(summary) };
  }

  stopAllTasks(actor: Actor): void {
    for (const task of this.taskRuns.values()) if (!task.summary.endedAt) this.cancelTask(task.summary.id, false, false, actor);
  }

  cancelTask(id: string, force = false, timeout = false, actor: Actor = daemonActor): TaskRunSummary {
    actor = this.actor(actor);
    const t = this.taskRuns.get(id);
    if (!t) throw notFound('RUN_NOT_FOUND', `任务运行不存在：${id}`);
    if (t.summary.endedAt) return structuredClone(t.summary);
    if (t.summary.state === 'cancelling' && !force) return structuredClone(t.summary);
    t.timedOut ||= timeout;
    t.r.requestedBy = timeout ? null : actor;
    t.summary.state = 'cancelling';
    this.sys(t.r, force ? '强制取消任务 · SIGKILL（模拟）' : '取消任务 · SIGTERM（模拟）');
    if (force || !this.taskSimulation.hangOnCancel) this.later(t.r, this.taskSimulation.cancelDelayMs, () => this.finishTask(id, t.timedOut ? 'timed-out' : 'cancelled', t.timedOut ? 'timeout' : force ? 'force-stop' : 'user-stop', null, force ? 'SIGKILL' : 'SIGTERM'));
    this.later(t.r, (t.cfg.stopTimeoutSec ?? this.limits.defaultStopTimeoutSec) * 1000, () => { if (!t.summary.endedAt) { t.summary.cancelTimedOut = true; this.upsert(t.p); } });
    this.upsert(t.p);
    return structuredClone(t.summary);
  }

  private finishTask(id: string, state: TaskRunSummary['state'], reason: ExitReason, code: number | null, signal: string | null): void {
    const t = this.taskRuns.get(id)!;
    if (t.summary.endedAt) return;
    this.clearTimers(t.r);
    const at = iso();
    t.summary.state = state; t.summary.endedAt = at; t.summary.exit = { reason, code, signal, at, requestedBy: reason === "timeout" || reason === "self-exit" ? null : t.r.requestedBy ?? daemonActor }; t.summary.cancelTimedOut = false;
    this.activity.add(t.p.project.id, t.summary.startedBy ?? daemonActor, { kind: "task-run", runId: id, taskKind: t.summary.kind, label: t.summary.label, state });
    t.r.summary.state = state === 'succeeded' ? 'exited' : state === 'cancelled' ? 'stopped' : 'failed';
    t.r.summary.endedAt = at; t.r.summary.exit = t.summary.exit; t.r.processes = [];
    this.sys(t.r, `任务结束 · ${state} · ${signal ?? `退出码 ${code}`}`);
    for (const sub of t.r.subscribers) { if (sub.timer) clearTimeout(sub.timer); this.flushSub(t.r, sub); sub.send({ type: 'end', runId: id, run: { ...t.summary } }); sub.close(); }
    t.r.subscribers.clear(); t.r.resolveEnded(); this.upsert(t.p); this.sampleAll();
  }

  // ───────────── runs & logs ─────────────

  runsOf(projectId: string, serviceId: string): RunSummary[] {
    const p = this.getProj(projectId);
    const s = this.svcRt(p, serviceId);
    return s.runs.map((r) => ({ ...r.summary })).reverse();
  }

  runDetail(runId: string): RunDetail {
    if (this.taskRuns.has(runId)) throw notFound('RUN_NOT_FOUND', '请从任务运行路由读取任务详情');
    return this.logRunDetail(runId);
  }
  private logRunDetail(runId: string): RunDetail {
    const r = this.findLogRun(runId);
    return {
      ...r.summary,
      command: [...r.command],
      cwd: r.cwd,
      envKeys: [...r.envKeys],
      params: structuredClone(r.params),
      log: this.logInfo(r),
      processes: r.processes.map((x) => ({ ...x })),
    };
  }

  private logInfo(r: RunRec) {
    return {
      firstSeq: r.lines[0]?.seq ?? null,
      lastSeq: r.lines[r.lines.length - 1]?.seq ?? null,
      bytes: r.bytes,
      truncated: r.truncated,
    };
  }

  /** Index of first line with seq >= target. */
  private lowerBound(lines: LogLine[], seq: number): number {
    let lo = 0;
    let hi = lines.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (lines[mid]!.seq < seq) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }

  logPage(runId: string, q: { before?: number; after?: number; limit?: number }): LogPage {
    const r = this.findLogRun(runId);
    const limit = Math.min(Math.max(1, q.limit ?? 500), this.limits.logPageMaxLines);
    let from: number;
    let to: number;
    if (q.before !== undefined) {
      to = this.lowerBound(r.lines, q.before);
      from = Math.max(0, to - limit);
    } else if (q.after !== undefined) {
      from = this.lowerBound(r.lines, q.after + 1);
      to = Math.min(r.lines.length, from + limit);
    } else {
      to = r.lines.length;
      from = Math.max(0, to - limit);
    }
    return {
      runId,
      lines: r.lines.slice(from, to),
      firstSeq: r.lines[0]?.seq ?? null,
      lastSeq: r.lines[r.lines.length - 1]?.seq ?? null,
      truncated: r.truncated,
      hasMoreBefore: from > 0,
      hasMoreAfter: to < r.lines.length,
      runEnded: r.summary.endedAt !== null,
    };
  }

  /** Attach a log stream subscriber; replays seq > afterSeq first. */
  subscribeLogs(runId: string, afterSeq: number, sub: LogSubscriber): () => void {
    const r = this.findLogRun(runId);
    const first = r.lines[0]?.seq ?? r.nextSeq;
    let start = afterSeq;
    if (afterSeq + 1 < first && (r.truncated || afterSeq > 0)) {
      sub.send({ type: 'truncated', runId, firstSeq: first });
      start = first - 1;
    }
    const idx = this.lowerBound(r.lines, start + 1);
    for (let i = idx; i < r.lines.length; i += 500) {
      const batch = r.lines.slice(i, i + 500);
      sub.send({ type: 'lines', runId, lines: batch });
    }
    sub.lastSentSeq = r.lines[r.lines.length - 1]?.seq ?? start;
    if (r.summary.endedAt) {
      sub.send({ type: 'end', runId, run: structuredClone(this.taskRuns.get(runId)?.summary ?? r.summary) });
      sub.close();
      return () => {};
    }
    r.subscribers.add(sub);
    return () => {
      r.subscribers.delete(sub);
      if (sub.timer) clearTimeout(sub.timer);
    };
  }

  private flushSub(r: RunRec, sub: LogSubscriber): void {
    sub.timer = null;
    if (sub.pending.length === 0) return;
    if (sub.backlog() > 8 * 1024 * 1024) {
      const dropped = sub.pending.length;
      const last = sub.pending[sub.pending.length - 1]!.seq;
      sub.pending = [];
      sub.send({ type: 'gap', runId: r.summary.id, afterSeq: last, reason: `客户端读取过慢，已丢弃 ${dropped} 行待发送日志` });
      sub.lastSentSeq = last;
      return;
    }
    const lines = sub.pending;
    sub.pending = [];
    for (let i = 0; i < lines.length; i += 500) sub.send({ type: 'lines', runId: r.summary.id, lines: lines.slice(i, i + 500) });
    sub.lastSentSeq = lines[lines.length - 1]!.seq;
  }

  appendLog(r: RunRec, stream: LogStream, text: string, ts: number = Date.now()): void {
    const max = this.limits.logLineMaxBytes;
    const parts: string[] = [];
    if (utf8Len(text) <= max) parts.push(text);
    else {
      // split on UTF-8 boundary (approximate by code points)
      let rest = text;
      while (utf8Len(rest) > max) {
        let n = max;
        while (utf8Len(rest.slice(0, n)) > max) n = Math.floor(n * 0.9);
        parts.push(rest.slice(0, n));
        rest = rest.slice(n);
      }
      parts.push(rest);
    }
    const tsIso = iso(ts);
    parts.forEach((t, i) => {
      const line: LogLine = { seq: r.nextSeq++, ts: tsIso, stream, text: t };
      if (i < parts.length - 1) line.partial = true;
      r.lines.push(line);
      if (r.summary.ready?.state === 'waiting' && r.readiness && ts-Date.parse(r.summary.startedAt) < (r.readiness.config.timeoutSec ?? 120)*1000) {
        const evidence = logEvidence(r.readiness, line);
        if (evidence) { r.summary.ready = { state: 'ready', at: iso(ts), afterMs: Math.max(0, ts-Date.parse(r.summary.startedAt)), evidence }; this.upsert(this.getProj(r.summary.projectId)); }
      }
      r.bytes += utf8Len(t) + 1;
      for (const sub of r.subscribers) {
        sub.pending.push(line);
        if (!sub.timer) sub.timer = setTimeout(() => this.flushSub(r, sub), 100);
      }
    });
    const byteLimit = this.taskRuns.has(r.summary.id) ? this.limits.logBytesPerTaskRun : this.limits.logBytesPerRun;
    if (r.bytes > byteLimit) {
      let drop = 0;
      while (r.bytes > byteLimit * 0.95 && drop < r.lines.length - 1) {
        r.bytes -= utf8Len(r.lines[drop]!.text) + 1;
        drop++;
      }
      r.lines.splice(0, drop);
      r.truncated = true;
    }
  }

  private sys(r: RunRec, text: string, ts?: number): void {
    this.appendLog(r, 'sys', text, ts);
  }

  private emitLines(r: RunRec, lines: Emit[], ts?: number): void {
    for (const l of lines) this.appendLog(r, l.stream, l.text, ts);
  }

  private dropRun(r: RunRec): void {
    this.clearTimers(r);
    for (const sub of r.subscribers) { if (sub.timer) clearTimeout(sub.timer); sub.close(); }
    r.subscribers.clear();
  }

  private clearTimers(r: RunRec): void {
    for (const t of r.timers) clearTimeout(t);
    r.timers.clear();
  }

  private later(r: RunRec, ms: number, fn: () => void): void {
    const t = setTimeout(() => {
      r.timers.delete(t);
      fn();
    }, ms);
    r.timers.add(t);
  }

  /**
   * @param startCfg project config as it was when this run started (defaults to the saved one;
   *   seeding passes older param values to simulate "changed since start").
   */
  private makeRun(p: ProjRec, s: SvcRt, cfg: ServiceConfig, startedAt: number, withPid: boolean, startCfg: ProjectConfig = p.project.config): RunRec {
    const svc = startCfg.services.find((x) => x.id === cfg.id) ?? cfg;
    const res = resolveService(startCfg, svc);
    const sub = substituteService(startCfg, svc);
    const profile = s.profileOverride ?? inferProfile(sub.display);
    const pid = withPid ? randInt(30000, 89000) : 0;
    const names = processesFor(profile.kind);
    const processes: ProcessInfo[] = withPid
      ? names.map((name, i) => ({
          pid: i === 0 ? pid : pid + i * randInt(3, 40),
          ppid: i === 0 ? process.pid : pid,
          startedAt: iso(startedAt + i * 300),
          command: name,
        }))
      : [];
    let resolveEnded!: () => void;
    const endedPromise = new Promise<void>((r) => (resolveEnded = r));
    const derived = deriveCtx(profile.kind, sub.display, sub.displayEnv);
    const ctx: SimCtx = { pid, childPid: processes[1]?.pid ?? pid, appName: startCfg.name, cwd: res.cwdAbs, ...derived };
    const plan = listenPlan(profile, ctx);
    const ready = readySnapshot(startCfg, cfg.ready);
    const run: RunRec = {
      ...(ready ? { readiness: { config: ready, seq: 0, tails: {} } } : {}),
      summary: {
        id: newRunId(startedAt),
        projectId: p.project.id,
        serviceId: cfg.id,
        configRevision: p.project.revision,
        startedAt: iso(startedAt),
        endedAt: null,
        pid: withPid ? pid : null,
        state: withPid ? 'starting' : 'failed',
        exit: null,
        startedBy: daemonActor,
        ready: ready ? { ...noReady(), state: "waiting" } : noReady(),
      },
      command: sub.display,
      cwd: res.cwdAbs,
      envKeys: sub.envKeys,
      params: sub.params,
      configSnapshot: this.effectiveSnapshot(startCfg, svc),
      listen: plan.ports,
      listenAfterMs: plan.afterMs,
      lines: [],
      nextSeq: 1,
      bytes: 0,
      truncated: false,
      processes,
      subscribers: new Set(),
      timers: new Set(),
      profile,
      ctx,
      sampleCount: 0,
      endedPromise,
      resolveEnded,
      stopRequestedWhileStarting: false,
      terminating: false,
    };
    s.runs.push(run);
    while (s.runs.length > this.limits.runsKeptPerService) {
      const old = s.runs.shift()!;
      this.dropRun(old);
    }
    return run;
  }

  private endRun(p: ProjRec, s: SvcRt, r: RunRec, reason: ExitReason, code: number | null, signal: string | null): void {
    if (r.summary.endedAt) return;
    this.clearTimers(r);
    const now = Date.now();
    const exit: ExitInfo = { reason, code, signal, at: iso(now), requestedBy: ["user-stop", "force-stop", "start-cancelled"].includes(reason) ? r.requestedBy ?? daemonActor : null };
    const finalState: ServiceState =
      reason === 'user-stop' || reason === 'force-stop' || reason === 'start-cancelled'
        ? 'stopped'
        : reason === 'self-exit' && code === 0
          ? 'exited'
          : 'failed';
    const desc = signal ? `signal=${signal}` : `code=${code}`;
    const who = reason === 'self-exit' ? '进程自行退出' : '进程已退出';
    this.sys(r, `${who} · ${desc} · 运行时长 ${formatDuration(now - Date.parse(r.summary.startedAt))}`);
    if (r.summary.ready?.state === "waiting") r.summary.ready = { ...noReady(), state: "ended-before-ready" };
    r.summary.endedAt = iso(now);
    r.summary.exit = exit;
    r.summary.state = finalState;
    r.processes = [];
    // flush & end subscribers
    for (const sub of r.subscribers) {
      if (sub.timer) clearTimeout(sub.timer);
      this.flushSub(r, sub);
      sub.send({ type: 'end', runId: r.summary.id, run: { ...r.summary } });
      sub.close();
    }
    r.subscribers.clear();
    if (s.currentRunId === r.summary.id) {
      s.currentRunId = null;
      s.state = finalState;
      s.stateSince = iso(now);
      s.stopTimedOut = false;
      // A self-exit failure is described by lastRun.exit; error stays null.
      s.error = null;
    }
    r.resolveEnded();
    this.upsert(p);
  }

  /** Start log generation and lifecycle timers for a live run. */
  private animate(p: ProjRec, s: SvcRt, r: RunRec, opts: { skipStartup?: boolean } = {}): void {
    const prof = r.profile;
    const startT = Date.now();
    if (!opts.skipStartup) {
      const lines = prof.portConflict ? startupLines(prof, r.ctx, startT).slice(0, 26) : startupLines(prof, r.ctx, startT);
      const span = prof.kind === 'spring' ? 5600 : prof.kind === 'uvicorn' ? 1500 : 500;
      lines.forEach((l, i) => this.later(r, Math.round((span * i) / Math.max(1, lines.length)), () => this.appendLog(r, l.stream, l.text)));
      if (prof.portConflict) {
        this.later(r, 3200, () => {
          this.emitLines(r, springPortConflict(r.ctx, Date.now()));
          this.later(r, 300, () => this.endRun(p, s, r, 'self-exit', 1, null));
        });
        return;
      }
    }
    const loop = () => {
      if (r.summary.endedAt || r.terminating) return;
      this.emitLines(r, tickLines(prof, r.ctx, Date.now()));
      this.later(r, tickInterval(prof) * rand(0.3, 1.7), loop);
    };
    this.later(r, opts.skipStartup ? rand(200, 2000) : prof.kind === 'spring' ? 6500 : 2000, loop);
    if (prof.exitAfterMs !== undefined) {
      this.later(r, prof.exitAfterMs, () => {
        this.appendLog(r, 'out', prof.exitCode === 0 || prof.exitCode === undefined ? 'Done.' : `Error: exited with ${prof.exitCode}`);
        this.endRun(p, s, r, 'self-exit', prof.exitCode ?? 0, null);
      });
    }
  }

  // ───────────── operations ─────────────

  getOperation(id: string): Operation {
    const o = this.operations.get(id);
    if (!o) throw notFound('OPERATION_NOT_FOUND', `操作不存在：${id}`);
    return structuredClone(o.op);
  }

  async waitOperation(id: string, timeoutMs: number): Promise<Operation> {
    const o = this.operations.get(id);
    if (!o) throw notFound('OPERATION_NOT_FOUND', `操作不存在：${id}`);
    if (!o.op.finishedAt) {
      await new Promise<void>((resolve) => {
        const t = setTimeout(done, Math.min(Math.max(0, timeoutMs), 60000));
        function done() {
          clearTimeout(t);
          o!.waiters.delete(done);
          resolve();
        }
        o.waiters.add(done);
      });
    }
    return structuredClone(o.op);
  }

  getPolicy(pid: string) { this.getProj(pid); return this.policies.get(pid); }
  setPolicy(pid: string, input: unknown, actor: Actor) {
    const project = this.getProj(pid);
    const policy = this.policies.set(pid, input, project.project.config.services.map(s => s.id), actor);
    this.upsert(project); return policy;
  }
  releaseHold(pid: string, sid: string, actor: Actor) {
    this.policies.ui(actor); const p = this.getProj(pid); this.svcCfg(p, sid);
    this.policies.release(pid, sid, actor); this.upsert(p);
  }
  submit(body: unknown, actor: Actor = { client: "cli", agent: null }, bypassPolicy = false): Operation {
    actor = this.actor(actor);
    const source = actor.client;
    if (!isObj(body)) throw badRequest('请求体必须是 ActionRequest');
    const req = body as unknown as ActionRequest;
    if (!['start', 'stop', 'restart', 'force-stop'].includes(req.action)) throw badRequest(`未知操作：${String(req.action)}`);
    if (req.serviceIds !== undefined && !Array.isArray(req.serviceIds)) throw badRequest('serviceIds 必须是数组');
    if (req.overrideHold !== undefined && typeof req.overrideHold !== "boolean") throw badRequest("overrideHold 必须为布尔值");
    const p = this.getProj(String(req.projectId));
    const ids = req.serviceIds && req.serviceIds.length ? [...new Set(req.serviceIds)] : p.project.config.services.map((s) => s.id);
    for (const id of ids) this.svcCfg(p, id);
    const op: Operation = {
      id: newOperationId(),
      projectId: p.project.id,
      action: req.action,
      serviceIds: ids,
      source, actor,
      state: 'queued',
      createdAt: iso(),
      finishedAt: null,
      results: ids.map((serviceId) => ({ serviceId, outcome: 'pending', runId: null, error: null })),
      cancelledBy: null,
    };
    const rec: OpRec = { op, waiters: new Set() };
    this.operations.set(op.id, rec);
    this.pruneOperations();
    const isStop = req.action === 'stop' || req.action === 'force-stop';
    for (const sid of ids) {
      const s = this.svcRt(p, sid);
      const denied = bypassPolicy ? null : this.policies.denial(p.project.id, sid, req.action, actor, req.overrideHold === true);
      if (isStop && !denied) this.cancelStarts(p, s, op.id);
      let resolveCancel!: () => void;
      const task: Task = {
        opRec: rec,
        serviceId: sid,
        action: req.action,
        cancelled: false,
        overrideHold: req.overrideHold === true,
        bypassPolicy,
        cancelPromise: new Promise<void>((r) => (resolveCancel = r)),
        cancel: () => {
          task.cancelled = true;
          resolveCancel();
        },
      };
      if (denied) { this.setResult(p, task, { outcome: "failed", error: denied, runId: null }); continue; }
      if (req.action === 'force-stop') {
        // force-stop does not wait behind a pending graceful stop
        s.forceActive = task;
        void this.execute(p, s, task).finally(() => {
          if (s.forceActive === task) s.forceActive = null;
        });
      } else {
        s.queue.push(task);
        this.pump(p, s);
      }
    }
    this.emit({ type: 'operation', operation: structuredClone(op) });
    this.upsert(p);
    return structuredClone(op);
  }

  private pruneOperations(): void {
    const cutoff = Date.now() - 15 * 60_000;
    for (const [id, o] of this.operations) if (o.op.finishedAt && Date.parse(o.op.finishedAt) < cutoff) this.operations.delete(id);
  }

  private cancelStarts(p: ProjRec, s: SvcRt, byOp: string): void {
    const keep: Task[] = [];
    for (const t of s.queue) {
      if (t.action === 'start' || t.action === 'restart') {
        t.cancelled = true;
        t.opRec.op.cancelledBy = byOp;
        this.setResult(p, t, { outcome: 'cancelled', runId: null, error: { code: 'OPERATION_CANCELLED', message: '被随后的停止操作取消' } });
      } else keep.push(t);
    }
    s.queue = keep;
    if (s.active && (s.active.action === 'start' || s.active.action === 'restart') && !s.active.cancelled) {
      s.active.opRec.op.cancelledBy = byOp;
      s.active.cancel();
    }
  }

  private pump(p: ProjRec, s: SvcRt): void {
    if (s.active || s.queue.length === 0) return;
    const task = s.queue.shift()!;
    s.active = task;
    void this.execute(p, s, task).finally(() => {
      s.active = null;
      this.pump(p, s);
      this.upsert(p);
    });
  }

  private async execute(p: ProjRec, s: SvcRt, task: Task): Promise<void> {
    const op = task.opRec.op;
    if (op.state === 'queued') {
      op.state = 'running';
      this.emit({ type: 'operation', operation: structuredClone(op) });
    }
    let result: Omit<OperationTargetResult, 'serviceId'>;
    try {
      const denied = task.bypassPolicy ? null : this.policies.denial(p.project.id, s.id, op.action, op.actor ?? daemonActor, task.overrideHold === true);
      result = denied ? { outcome: "failed", error: denied, runId: null } : await this.runTask(p, s, task);
    } catch (e) {
      result = { outcome: 'failed', runId: null, error: { code: 'INTERNAL', message: String(e) } };
    }
    this.setResult(p, task, result);
  }

  private setResult(p: ProjRec, task: Task, result: Omit<OperationTargetResult, 'serviceId'>): void {
    const op = task.opRec.op;
    const target = op.results.find((r) => r.serviceId === task.serviceId);
    if (!target || target.outcome !== 'pending') return;
    target.outcome = result.outcome;
    target.runId = result.runId;
    target.error = result.error;
    if (!task.bypassPolicy) this.policies.outcome(op, target, op.actor ?? daemonActor, task.overrideHold === true);
    if (op.results.every((r) => r.outcome !== 'pending')) {
      const desired = DESIRED[op.action];
      const ok = op.results.filter((r) => desired.includes(r.outcome)).length;
      const cancelled = op.results.filter((r) => r.outcome === 'cancelled').length;
      op.state = cancelled === op.results.length ? 'cancelled' : ok === op.results.length ? 'succeeded' : ok === 0 ? 'failed' : 'partial';
      op.finishedAt = iso();
      this.activity.add(p.project.id, op.actor ?? daemonActor, { kind: "operation", operationId: op.id, action: op.action, serviceIds: op.serviceIds, state: op.state, ...(this.policies.overridden.delete(op.id) ? { overrideHold: true } : {}), results: op.results.map(r => ({ serviceId: r.serviceId, outcome: r.outcome, runId: r.runId, errorCode: r.error?.code ?? null })) });
      for (const w of [...task.opRec.waiters]) w();
    }
    this.emit({ type: 'operation', operation: structuredClone(op) });
    this.upsert(p);
  }

  private async runTask(p: ProjRec, s: SvcRt, task: Task): Promise<Omit<OperationTargetResult, 'serviceId'>> {
    switch (task.action) {
      case 'start':
        return this.doStart(p, s, task);
      case 'stop':
        return this.doStop(p, s, task, false);
      case 'force-stop':
        return this.doForceStop(p, s, task);
      case 'restart': {
        if (task.cancelled) return { outcome: 'cancelled', runId: null, error: null };
        if (this.currentRun(s)) {
          const r = await this.doStop(p, s, task, true);
          if (task.cancelled) return { outcome: 'cancelled', runId: r.runId, error: { code: 'OPERATION_CANCELLED', message: '被随后的停止操作取消' } };
          if (r.outcome !== 'stopped' && r.outcome !== 'already-stopped') {
            return {
              outcome: 'failed',
              runId: r.runId,
              error: { code: 'STOP_TIMEOUT', message: '旧进程未能在时限内停止，未启动新进程', details: { runId: r.runId } },
            };
          }
        }
        return this.doStart(p, s, task);
      }
    }
  }

  private async doStart(p: ProjRec, s: SvcRt, task: Task): Promise<Omit<OperationTargetResult, 'serviceId'>> {
    if (task.cancelled) return { outcome: 'cancelled', runId: null, error: { code: 'OPERATION_CANCELLED', message: '被随后的停止操作取消' } };
    if (s.state === 'starting' || s.state === 'running') return { outcome: 'already-running', runId: s.currentRunId, error: null };
    if (s.state === 'unknown') {
      return { outcome: 'failed', runId: null, error: { code: 'STATE_UNVERIFIABLE', message: '服务状态无法核验，已阻止启动以避免重复实例' } };
    }
    if (s.state === 'stopping') {
      return { outcome: 'failed', runId: s.currentRunId, error: { code: 'STOP_TIMEOUT', message: '上一次运行尚未停止，不能启动新进程' } };
    }
    const cfg = this.svcCfg(p, s.id);
    // Resolve the program the way it will actually be spawned: after ${key} substitution.
    const sub = substituteService(p.project.config, cfg);
    const res = resolveService({ ...p.project.config, env: {} }, { ...cfg, command: sub.command, env: sub.env });
    if (res.program !== sub.display[0]) res.program = sub.display[0] ?? '';
    const now = Date.now();
    if (!res.cwdExists || !res.programResolved) {
      const run = this.makeRun(p, s, cfg, now, false);
      run.summary.startedBy = task.opRec.op.actor ?? daemonActor;
      const error: ApiError = !res.cwdExists
        ? { code: 'CWD_UNAVAILABLE', message: `工作目录不存在：${res.cwdAbs}`, details: { cwd: res.cwdAbs } }
        : {
            code: 'COMMAND_NOT_FOUND',
            message: `在 PATH 中找不到 ${res.program}`,
            details: { program: res.program, pathUsed: res.pathUsed },
          };
      this.sys(run, `启动失败 · ${error.message}${error.code === 'COMMAND_NOT_FOUND' ? `（PATH：${res.pathUsed}）` : ''}`);
      if (run.summary.ready?.state === "waiting") run.summary.ready = { ...noReady(), state: "ended-before-ready" };
      run.summary.endedAt = iso();
      run.summary.exit = { reason: 'spawn-failed', code: null, signal: null, at: iso(), requestedBy: null };
      run.summary.state = 'failed';
      run.resolveEnded();
      s.state = 'failed';
      s.stateSince = iso();
      s.error = error;
      this.upsert(p);
      return { outcome: 'failed', runId: run.summary.id, error };
    }
    const run = this.makeRun(p, s, cfg, now, true);
    run.summary.startedBy = task.opRec.op.actor ?? daemonActor;
    s.currentRunId = run.summary.id;
    s.state = 'starting';
    s.stateSince = iso(now);
    s.error = null;
    s.stopTimedOut = false;
    this.sys(run, `已启动 · 运行 ${run.summary.id} · PID ${run.summary.pid} · ${displayArgv(run.command)}`);
    this.animate(p, s, run);
    this.upsert(p);
    await Promise.race([sleep(this.limits.startGraceMs), task.cancelPromise, run.endedPromise]);
    if (task.cancelled) {
      return { outcome: 'cancelled', runId: run.summary.id, error: { code: 'OPERATION_CANCELLED', message: '被随后的停止操作取消' } };
    }
    if (run.summary.endedAt) {
      const error: ApiError = {
        code: 'EXITED_DURING_START',
        message: `进程在启动观察期内退出（code=${run.summary.exit?.code ?? 'null'}）`,
        details: { code: run.summary.exit?.code ?? null, signal: run.summary.exit?.signal ?? null },
      };
      if (s.currentRunId === null && s.runs[s.runs.length - 1] === run) {
        s.state = 'failed';
        s.error = error;
        this.upsert(p);
      }
      return { outcome: 'failed', runId: run.summary.id, error };
    }
    s.state = 'running';
    s.stateSince = iso();
    run.summary.state = 'running';
    this.upsert(p);
    return { outcome: 'started', runId: run.summary.id, error: null };
  }

  private async doStop(p: ProjRec, s: SvcRt, task: Task, forRestart: boolean): Promise<Omit<OperationTargetResult, 'serviceId'>> {
    const run = this.currentRun(s);
    if (!run) return { outcome: 'already-stopped', runId: s.runs[s.runs.length - 1]?.summary.id ?? null, error: null };
    const cfg = this.svcCfg(p, s.id);
    const timeoutSec = cfg.stopTimeoutSec ?? this.limits.defaultStopTimeoutSec;
    run.requestedBy = task.opRec.op.actor ?? daemonActor;
    if (s.state === 'starting') run.stopRequestedWhileStarting = true;
    if (s.state !== 'stopping') {
      s.state = 'stopping';
      s.stateSince = iso();
    }
    s.stopTimedOut = false;
    run.summary.state = 'stopping';
    const who = task.opRec.op.source === 'ui' ? '用户在面板请求' : task.opRec.op.source === 'cli' ? 'CLI 请求' : '管理服务';
    this.sys(run, `${who}${forRestart ? '重启' : '停止'} · 向进程组 ${run.summary.pid} 发送 SIGTERM`);
    this.upsert(p);
    if (!run.terminating) {
      run.terminating = true;
      this.later(run, rand(150, 400), () => this.emitLines(run, termLines(run.profile, run.ctx, Date.now())));
      if (!run.profile.hangOnStop) {
        this.later(run, rand(500, 1600), () =>
          this.endRun(p, s, run, run.stopRequestedWhileStarting ? 'start-cancelled' : 'user-stop', null, 'SIGTERM'),
        );
      }
    }
    await Promise.race([run.endedPromise, sleep(timeoutSec * 1000)]);
    if (run.summary.endedAt) return { outcome: 'stopped', runId: run.summary.id, error: null };
    s.stopTimedOut = true;
    const pids = run.processes.map((x) => x.pid);
    this.sys(run, `等待退出中：已等待 ${timeoutSec} 秒，仍有 ${pids.length} 个受管进程（${pids.join(', ')}）`);
    this.upsert(p);
    return {
      outcome: 'stop-timeout',
      runId: run.summary.id,
      error: {
        code: 'STOP_TIMEOUT',
        message: `已发送 SIGTERM，${timeoutSec} 秒内仍有 ${pids.length} 个受管进程未退出`,
        details: { timeoutSec, remaining: pids.length },
      },
    };
  }

  private async doForceStop(p: ProjRec, s: SvcRt, task: Task): Promise<Omit<OperationTargetResult, 'serviceId'>> {
    const run = this.currentRun(s);
    if (!run) return { outcome: 'already-stopped', runId: s.runs[s.runs.length - 1]?.summary.id ?? null, error: null };
    if (s.state !== 'stopping') {
      s.state = 'stopping';
      s.stateSince = iso();
    }
    run.summary.state = 'stopping';
    run.requestedBy = task.opRec.op.actor ?? daemonActor;
    run.terminating = true;
    const pids = run.processes.map((x) => x.pid);
    this.sys(run, `强制停止 · 向 ${pids.length} 个受管进程发送 SIGKILL（${pids.join(', ')}）`);
    this.upsert(p);
    this.later(run, 200, () => this.endRun(p, s, run, 'force-stop', null, 'SIGKILL'));
    await Promise.race([run.endedPromise, sleep(5000)]);
    if (run.summary.endedAt) return { outcome: 'stopped', runId: run.summary.id, error: null };
    return { outcome: 'failed', runId: run.summary.id, error: { code: 'INTERNAL', message: '发送 SIGKILL 后进程仍未退出' } };
  }

  // ───────────── stats ─────────────

  /** One sampling cycle (normally driven by the stats timer; public for tests). */
  private updateReady() {
    const now = Date.now();
    for (const p of this.projects) for (const s of p.services.values()) for (const r of s.runs) {
      if (r.summary.ready?.state !== 'waiting' || !r.readiness) continue;
      const elapsed = now-Date.parse(r.summary.startedAt);
      if (elapsed >= (r.readiness.config.timeoutSec ?? 120)*1000) r.summary.ready = { ...noReady(), state: 'timed-out', at: iso(now) };
      else {
        const evidence = r.readiness.config.check.kind === "port" ? portEvidence(r.readiness.config, this.sampleListening(r,now)) : null;
        if (evidence) r.summary.ready = { state: 'ready', at: iso(now), afterMs: elapsed, evidence };
      }
      if (r.summary.ready.state !== 'waiting') this.upsert(p);
    }
  }
  sampleAll(): void {
    this.updateReady();
    const now = Date.now();
    this.selfSample = {
      status: 'ok', sampledAt: iso(now), cpuPercent: 0.6,
      rssBytes: 64 * 1024 ** 2, footprintBytes: 32 * 1024 ** 2,
      processCount: 1, note: 'mock 模拟管理进程',
    };
    const projects: Record<string, ProjectStats> = {};
    for (const p of this.projects) {
      const services: Record<string, ServiceStats> = {};
      for (const s of p.services.values()) {
        const r = this.currentRun(s);
        if (!r) continue;
        services[s.id] = { runId: r.summary.id, ...this.sampleRun(r, s, now), listening: this.sampleListening(r, now) };
      }
      const tasks: ProjectStats['tasks'] = {};
      for (const t of this.taskRuns.values()) if (t.p === p && !t.summary.endedAt) tasks[t.summary.id] = { runId: t.summary.id, listening: null, status: 'ok', sampledAt: iso(now), cpuPercent: 12, rssBytes: 64 * 1024 ** 2, footprintBytes: 72 * 1024 ** 2, processCount: t.r.processes.length };
      if (Object.keys(services).length === 0 && Object.keys(tasks).length === 0) continue;
      projects[p.project.id] = { total: totalOf([...Object.values(services), ...Object.values(tasks)], now), services, tasks };
    }
    if (Object.keys(projects).length === 0 && this.lastStats && Object.keys(this.lastStats.projects).length === 0) return;
    this.lastStats = { sampledAt: iso(now), intervalMs: this.limits.statsIntervalMs, projects };
    this.emit({ type: 'stats', stats: this.lastStats });
  }

  /** v1.1-B: null until the simulated server has bound its sockets, and occasionally null (read failure). */
  private sampleListening(r: RunRec, now: number): ListeningPort[] | null {
    if (r.summary.endedAt) return null;
    const age = now - Date.parse(r.summary.startedAt);
    if (age < (this.sim.listenDelayMs ?? r.listenAfterMs)) return null;
    if (Math.random() < this.sim.listenFailRate) return null;
    return r.listen.map((x) => ({ ...x }));
  }

  private sampleRun(r: RunRec, s: SvcRt, now: number): ResourceSample {
    r.sampleCount++;
    const base = baseline(r.profile);
    const n = r.processes.length;
    const ageMs = now - Date.parse(r.summary.startedAt);
    let cpu = base.cpu * rand(0.85, 1.15);
    if (r.profile.kind === 'spring' && ageMs < 8000) cpu = rand(220, 340);
    if (s.state === 'stopping') cpu = rand(0.1, 0.6);
    let rss = base.rssMiB * 1024 * 1024 * rand(0.97, 1.03) * (r.profile.kind === 'spring' && ageMs < 8000 ? Math.min(1, ageMs / 8000 + 0.3) : 1);
    if (r.sampleCount === 1) {
      return { status: 'sampling', sampledAt: iso(now), cpuPercent: null, rssBytes: Math.round(rss), footprintBytes: Math.round(rss * 1.2), processCount: n };
    }
    if (Math.random() < this.sim.resourceFailRate && n > 1) {
      cpu *= 0.8;
      rss *= 0.85;
      return {
        status: 'partial',
        sampledAt: iso(now),
        cpuPercent: round1(cpu),
        rssBytes: Math.round(rss),
        footprintBytes: null,
        processCount: n,
        note: `${n} 个进程中有 1 个无法读取（权限不足或已退出），数值偏低`,
      };
    }
    return { status: 'ok', sampledAt: iso(now), cpuPercent: round1(cpu), rssBytes: Math.round(rss), footprintBytes: Math.round(rss * 1.2), processCount: n };
  }

  // ───────────── seeding & debug ─────────────

  seedProject(cfg: ProjectConfig, opts: { revision: number; createdAt: number; id?: string }): ProjRec {
    const rec: ProjRec = {
      project: { id: opts.id ?? newProjectId(), revision: opts.revision, createdAt: iso(opts.createdAt), updatedAt: iso(opts.createdAt + 3600_000), config: cfg },
      services: new Map(),
    };
    for (const s of cfg.services) rec.services.set(s.id, this.newSvcRt(s.id));
    this.projects.push(rec);

    return rec;
  }

  setProfile(p: ProjRec, sid: string, profile: SimProfile): void {
    this.svcRt(p, sid).profileOverride = profile;
  }

  /** A finished run with pre-generated logs. */
  seedHistoricRun(
    p: ProjRec,
    sid: string,
    spec: {
      startedAt: number;
      endedAt: number;
      reason: ExitReason;
      code: number | null;
      signal: string | null;
      configRevision?: number;
      ticks?: number;
      portConflict?: boolean;
      dropFirst?: number;
      /** Param values in effect when this run started. */
      paramValues?: Record<string, ParamValue>;
    },
  ): void {
    const s = this.svcRt(p, sid);
    const cfg = this.svcCfg(p, sid);
    const r = this.makeRun(p, s, cfg, spec.startedAt, true, withParamValues(p.project.config, spec.paramValues));
    if (spec.configRevision !== undefined) r.summary.configRevision = spec.configRevision;
    const t0 = spec.startedAt;
    this.sys(r, `已启动 · 运行 ${r.summary.id} · PID ${r.summary.pid} · ${displayArgv(r.command)}`, t0);
    const startup = startupLines(r.profile, r.ctx, t0);
    const startupLen = spec.portConflict ? 26 : startup.length;
    startup.slice(0, startupLen).forEach((l, i) => this.appendLog(r, l.stream, l.text, t0 + i * 120));
    if (spec.portConflict) {
      for (const l of springPortConflict(r.ctx, t0 + 4000)) this.appendLog(r, l.stream, l.text, t0 + 4000);
    } else {
      const ticks = spec.ticks ?? 200;
      const span = spec.endedAt - t0 - 8000;
      for (let i = 0; i < ticks; i++) {
        const t = t0 + 7000 + Math.round((span * i) / ticks);
        for (const l of tickLines(r.profile, r.ctx, t)) this.appendLog(r, l.stream, l.text, t);
      }
      if (spec.reason === 'self-exit' && spec.code !== 0) {
        const t = spec.endedAt - 400;
        const crash =
          r.profile.kind === 'spring'
            ? [
                'Exception in thread "http-nio-8080-Poller" java.lang.OutOfMemoryError: Java heap space',
                '\tat java.base/java.util.Arrays.copyOf(Arrays.java:3541)',
                '\tat java.base/java.lang.AbstractStringBuilder.ensureCapacityInternal(AbstractStringBuilder.java:242)',
                '\tat com.example.order.report.ReportExporter.render(ReportExporter.java:77)',
                '[ERROR] Failed to execute goal org.springframework.boot:spring-boot-maven-plugin:3.4.1:run (default-cli): Process terminated with exit code: 1',
              ]
            : ['Error: process crashed'];
        for (const text of crash) this.appendLog(r, 'err', text, t);
      }
      if (spec.reason === 'user-stop') {
        this.sys(r, `用户在面板请求停止 · 向进程组 ${r.summary.pid} 发送 SIGTERM`, spec.endedAt - 900);
        for (const l of termLines(r.profile, r.ctx, spec.endedAt - 600)) this.appendLog(r, l.stream, l.text, spec.endedAt - 600);
      }
    }
    if (spec.dropFirst) {
      const drop = Math.min(spec.dropFirst, r.lines.length - 10);
      for (let i = 0; i < drop; i++) r.bytes -= utf8Len(r.lines[i]!.text) + 1;
      r.lines.splice(0, drop);
      r.truncated = true;
    }
    // Deterministic digest fixtures cover duplicates, chained Java/Python stacks and benign stderr.
    if (spec.portConflict) {
      for (let i = 0; i < 50; i++) {
        this.appendLog(r, 'err', 'ERROR repeated startup failure 8080', spec.endedAt - 100);
        for (let j = 0; j < 12; j++) this.appendLog(r, 'err', `    at demo.Server.start(Server.java:${j})`, spec.endedAt - 100);
        this.appendLog(r, 'err', 'Caused by: java.net.BindException: Address in use', spec.endedAt - 100);
        for (let j = 0; j < 6; j++) this.appendLog(r, 'err', `    at demo.Bind.listen(Bind.java:${j})`, spec.endedAt - 100);
      }
      for (const text of ['Traceback (most recent call last):', '  File "server.py", line 42', '    raise TypeError("bad")', 'TypeError: bad', 'normal stderr progress']) this.appendLog(r, 'err', text, spec.endedAt - 90);
    }
    const desc = spec.signal ? `signal=${spec.signal}` : `code=${spec.code}`;
    this.sys(r, `${spec.reason === 'self-exit' ? '进程自行退出' : '进程已退出'} · ${desc} · 运行时长 ${formatDuration(spec.endedAt - t0)}`, spec.endedAt);
    if (r.summary.ready?.state === "waiting") r.summary.ready = { ...noReady(), state: "ended-before-ready" };
    r.summary.endedAt = iso(spec.endedAt);
    r.summary.exit = { reason: spec.reason, code: spec.code, signal: spec.signal, at: iso(spec.endedAt), requestedBy: ["user-stop", "force-stop", "start-cancelled"].includes(spec.reason) ? { client: "ui", agent: null } : null };
    r.summary.state = spec.reason === 'self-exit' ? (spec.code === 0 ? 'exited' : 'failed') : 'stopped';
    r.processes = [];
    r.resolveEnded();
    s.state = r.summary.state;
    s.stateSince = r.summary.endedAt;
    s.error = null;
    s.currentRunId = null;
  }

  /** A run that is already running (started some time ago), with backfilled logs. */
  seedLiveRun(
    p: ProjRec,
    sid: string,
    spec: { startedAt: number; configRevision?: number; configSnapshot?: string; paramValues?: Record<string, ParamValue> },
  ): void {
    const s = this.svcRt(p, sid);
    const cfg = this.svcCfg(p, sid);
    const r = this.makeRun(p, s, cfg, spec.startedAt, true, withParamValues(p.project.config, spec.paramValues));
    if (spec.configRevision !== undefined) r.summary.configRevision = spec.configRevision;
    if (spec.configSnapshot !== undefined) r.configSnapshot = spec.configSnapshot;
    const t0 = spec.startedAt;
    this.sys(r, `已启动 · 运行 ${r.summary.id} · PID ${r.summary.pid} · ${displayArgv(r.command)}`, t0);
    startupLines(r.profile, r.ctx, t0).forEach((l, i) => this.appendLog(r, l.stream, l.text, t0 + i * 120));
    const now = Date.now();
    const mean = tickInterval(r.profile);
    for (let t = t0 + 7000; t < now - 1000; t += mean * rand(0.3, 1.7)) {
      for (const l of tickLines(r.profile, r.ctx, t)) this.appendLog(r, l.stream, l.text, t);
    }
    r.summary.state = 'running';
    s.state = 'running';
    s.stateSince = iso(t0 + 1000);
    s.currentRunId = r.summary.id;
    r.sampleCount = 1;
    this.animate(p, s, r, { skipStartup: true });
  }

  /** Debug: inject a burst of lines into a run. */
  flood(runId: string, count: number): { runId: string; count: number } {
    const r = this.findLogRun(runId);
    let i = 0;
    const base = r.nextSeq;
    const step = () => {
      const end = Math.min(count, i + 5000);
      const now = Date.now();
      for (; i < end; i++) {
        const l = floodLine(base + i, now);
        this.appendLog(r, l.stream, l.text, now);
      }
      if (i < count) setTimeout(step, 30);
    };
    step();
    return { runId, count };
  }

  /** Debug: the run that UI most likely looks at (first running run), for flood without runId. */
  anyLiveRunId(): string | null {
    for (const p of this.projects) for (const s of p.services.values()) if (s.currentRunId) return s.currentRunId;
    return null;
  }
}

/** argv as one readable line for sys log lines; elements that need it are single-quoted. */
export function displayArgv(argv: string[]): string {
  return argv
    .map((a) => (a === '' ? "''" : /^[\w@%+=:,./\-]+$/.test(a.replaceAll(MASK, '')) || a === MASK ? a : `'${a.replaceAll("'", `'\\''`)}'`))
    .join(' ');
}

function round1(n: number): number {
  return Math.round(n * 10) / 10;
}

function totalOf(samples: ResourceSample[], now: number): ResourceSample {
  const footprintBytes = samples.every(s => s.footprintBytes != null) ? samples.reduce((n, s) => n + s.footprintBytes!, 0) : null;
  const sampling = samples.filter((s) => s.status === 'sampling').length;
  const partial = samples.filter((s) => s.status === 'partial').length;
  const unavailable = samples.filter((s) => s.status === 'unavailable').length;
  const usable = samples.filter((s) => s.status === 'ok' || s.status === 'partial');
  const rssKnown = samples.filter((s) => s.rssBytes !== null);
  if (sampling === samples.length) {
    return {
      status: 'sampling',
      footprintBytes,
      sampledAt: iso(now),
      cpuPercent: null,
      rssBytes: rssKnown.length ? rssKnown.reduce((a, s) => a + (s.rssBytes ?? 0), 0) : null,
      processCount: samples.reduce((a, s) => a + (s.processCount ?? 0), 0),
    };
  }
  if (unavailable === samples.length) {
    return { status: 'unavailable', sampledAt: iso(now), cpuPercent: null, rssBytes: null, footprintBytes: null, processCount: null, note: '全部进程都无法读取' };
  }
  const total: ResourceSample = {
    footprintBytes,
    status: partial || sampling || unavailable ? 'partial' : 'ok',
    sampledAt: iso(now),
    cpuPercent: round1(usable.reduce((a, s) => a + (s.cpuPercent ?? 0), 0)),
    rssBytes: rssKnown.reduce((a, s) => a + (s.rssBytes ?? 0), 0),
    processCount: samples.reduce((a, s) => a + (s.processCount ?? 0), 0),
  };
  if (total.status === 'partial') {
    total.note = sampling ? '部分服务仍在首次采样，合计不含其 CPU' : '部分进程无法读取，合计偏低';
  }
  return total;
}

export function aggregate(states: ServiceState[]): ProjectAggregate {
  if (states.some((s) => s === 'unknown')) return 'unknown';
  const failed = states.some((s) => s === 'failed');
  if (!failed && states.some((s) => s === 'starting' || s === 'stopping')) return 'transition';
  const running = states.filter((s) => s === 'running').length;
  if (running === states.length && running > 0) return 'running';
  if (running > 0) return 'partial';
  if (failed) return 'failed';
  if (states.every((s) => s === 'idle')) return 'idle';
  return 'stopped';
}
