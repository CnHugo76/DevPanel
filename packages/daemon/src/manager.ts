import { mavenTarget } from "./project-targets.ts";
import { noReady, readySnapshot, logEvidence, readyTimeoutMs, portEvidence, type ReadyTracking } from "./ready.ts";
import { spawn, type ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { join, resolve } from "node:path";
import { existsSync, realpathSync } from "node:fs";
import type {
  ActionRequest,
  ActionConfig, TaskRunSummary, TaskRunDetail, MavenRunRequest, StartTaskRunResponse,
  Actor, ActivityEntry, ProjectPolicy, ServiceHold,
  DaemonEvent,
  DaemonInfo,
  Project,
  ProjectConfig,
  ProjectView,
  ServiceView,
  RunDetail,
  RunSummary,
  Operation,
  OperationTargetResult,
  ProcessInfo,
  ProjectStats,
  StatsSnapshot,
  ApiError,
  Limits,
  ServiceConfig,
  ResourceSample,
} from "@devpanel/contract";
import {
  atomicWrite,
  readJSON,
  id,
  now,
  Fault,
  limits as defaults,
  unavailable,
  sleep,
  VERSION,
} from "./storage.ts";
import {
  baseEnvironment,
  effectiveEnv,
  validate,
  resolveSecrets,
  canonical,
  mask,
  secrets,
  redact,
  findProgram,
  type BaseEnv,
} from "./config.ts";
import {
  discover,
  verifiedSignal,
  resourceSample,
  identity,
  type ProcessRow,
} from "./processes.ts";
import {
  paramIssues,
  serviceParams,
  comparable,
  expandService,
  prepareParams,
  uses,
  inlineParam,
} from "./params.ts";
import { Policies } from "./policy.ts";
import { Activities, daemonActor, configDiff } from "./activity.ts";
import { serviceListening } from "./listening.ts";
import { ProcessScanner } from "./process-scanner.ts";
import { daemonLog } from "./daemon-log.ts";
import { Logs } from "./logs.ts";
import type { Git } from "./git.ts";
import { TaskRuns, type TaskMetadata, type TaskTarget } from "./task-runs.ts";
import type { MavenModels } from "./maven.ts";

export interface StoredRun {
  /** Per-run live tracking; persisted for diagnostics, never used to reattach old pipes. */
  readiness?: ReadyTracking;
  task?: TaskMetadata;
  requestedBy?: Actor | null;
  detail: RunDetail;
  // Private persisted snapshot; never included in RunDetail or events.
  configSnapshot?: ServiceConfig;
  stateSince?: string;
  known: ProcessInfo[];
  stopping: boolean;
  stopTimedOut: boolean;
  error: ApiError | null;
  rootExit: { code: number | null; signal: string | null } | null;
  sequenceFloor: number;
  sensitive: string[];
  boot: number;
}
interface Disk {
  projects: Project[];
  runs: StoredRun[];
  activity?: ActivityEntry[];
  policies?: Record<string, ProjectPolicy>;
  holds?: Record<string, Record<string, ServiceHold>>;
}
export interface ManagedOperation {
  operation: Operation;
  result: OperationTargetResult;
  cancelled: boolean;
  cancelledByActor?: Actor;
}
export const activeStates = new Set([
  "starting",
  "running",
  "stopping",
  "unknown",
]);
export const terminal = (op: Operation) =>
  !["queued", "running"].includes(op.state);
const publicProcess = (p: ProcessInfo): ProcessInfo => ({
  pid: p.pid,
  ppid: p.ppid,
  startedAt: p.startedAt,
  command: p.command,
});
const delayedSample = (previous: ResourceSample): ResourceSample => ({
  ...previous, status: "partial", cpuPercent: null, footprintBytes: null,
  note: "原生采样暂时失败，等待重试；保留上次样本时间，数值可能过期",
});
export class Manager extends EventEmitter {
  shuttingDown = false;
  projects = new Map<string, Project>();
  runs = new Map<string, StoredRun>();
  operations = new Map<string, Operation>();
  tasks = new Map<string, ManagedOperation[]>();
  readonly taskRunner = new TaskRuns(this);
  queues = new Map<string, Promise<void>>();
  children = new Map<string, ChildProcess>();
  logs: Logs;
  base: BaseEnv;
  limits: Limits;
  startedAt = now();
  stats: StatsSnapshot | null = null;
  boot: number;
  private readonly scanner: ProcessScanner;
  private lastDiscovery = 0;
  private scanning: Promise<void> | null = null;
  private timer: NodeJS.Timeout;
  private lastStats = 0;
  private lastReadyPorts = 0;
  private prior = new Map<string, { cpu: number; at: number }>();
  private cpu = process.cpuUsage();
  private cpuAt = performance.now();
  private selfSample: ResourceSample = unavailable();
  private selfTimer: NodeJS.Timeout;
  private selfSampling: Promise<void> | null = null;
  private toolPrior = new Map<string, { cpu: number; at: number }>();
  private toolSample: NonNullable<DaemonInfo["toolResources"]> = {
    daemon: unavailable(), helpers: unavailable(), total: unavailable(),
  };
  private dirty = false;
  private saveTimer: NodeJS.Timeout;
  private closed = false;
  policies: Policies;
  activity: Activities;
  home: string;
  constructor(home: string, boot: number, limits: Limits = defaults) {
    super();
    this.home = home;
    this.boot = boot;
    this.limits = { ...limits, activityKeptPerProject: limits.activityKeptPerProject ?? 500 };
    this.base = readJSON(join(home, "environment.json"), baseEnvironment());
    atomicWrite(join(home, "environment.json"), this.base);
    this.scanner = new ProcessScanner(undefined, { log: line => daemonLog(home, line) });
    this.logs = new Logs(home, limits, (runId) =>
      this.emit("gap", { runId, reason: "日志持久化失败，内存日志仍在采集" }),
    );
    this.logs.onLine = (rid, line) => {
      const r = this.runs.get(rid);
      if (r?.detail.ready?.state !== "waiting" || !r.readiness) return;
      if (Date.now() - Date.parse(r.detail.startedAt) >= readyTimeoutMs(r.readiness.config)) { this.setReady(r, "timed-out"); return; }
      const evidence = logEvidence(r.readiness, line);
      this.dirty = true;
      if (evidence) this.setReady(r, "ready", evidence);
    };
    this.logs.reserveSequence = (rid, exclusive) => {
      const run = this.runs.get(rid);
      if (run) {
        run.sequenceFloor = exclusive;
        this.save();
      }
    };
    this.logs.onGlobalOverflow = () => {
      for (const [rid, r] of this.runs) {
        if (activeStates.has(r.detail.state)) continue;
        this.runs.delete(rid);
        this.logs.delete(rid);
        this.dirty = true;
        if (
          [...this.logs.states.values()].reduce((n, s) => n + s.bytes, 0) <=
          this.limits.logBytesGlobal
        )
          break;
      }
    };
    const disk = readJSON<Disk>(join(home, "state.json"), {
      projects: [],
      runs: [],
    });
    this.activity = new Activities(disk.activity, limits.activityKeptPerProject ?? 500);
    this.policies = new Policies(this.activity, disk.policies, disk.holds);
    for (const p of disk.projects) this.projects.set(p.id, p);
    for (const r of disk.runs) {
      r.detail.params ??= {};
      r.detail.startedBy ??= null;
      if (r.detail.exit) r.detail.exit.requestedBy ??= null;
      r.detail.ready ??= noReady();
      // Repair terminal records saved before daemon-lost cleared transient errors.
      if (
        r.detail.endedAt &&
        r.detail.exit?.reason === "daemon-lost" &&
        (r.error !== null || r.stopTimedOut)
      ) {
        r.error = null;
        r.stopTimedOut = false;
        this.dirty = true;
      }
      // Migrate old records only when the saved revision still proves the startup config.
      if (!r.configSnapshot && !r.task) {
        const project = this.projects.get(r.detail.projectId);
        const service = project?.config.services.find(
          (s) => s.id === r.detail.serviceId,
        );
        if (project?.revision === r.detail.configRevision && service)
          r.configSnapshot = this.serviceSnapshot(project.config, service);
      }
      if (r.task && !r.task.target) {
        const old = r.task as unknown as { kind: "action" | "maven"; actionId: string; maven: MavenRunRequest };
        r.task.target = old.kind === "maven" ? { kind: "maven", request: old.maven } : { kind: "action", actionId: old.actionId };
        delete (r.task as any).kind; delete (r.task as any).actionId; delete (r.task as any).maven;
      }
      this.runs.set(r.detail.id, r);
      this.logs.create(r.detail.id, r.sequenceFloor, r.task ? limits.logBytesPerTaskRun : limits.logBytesPerRun);
    }
    this.timer = setInterval(() => {
      for (const r of this.runs.values()) {
        if (r.detail.ready?.state === "waiting" && r.readiness && Date.now() - Date.parse(r.detail.startedAt) >= readyTimeoutMs(r.readiness.config)) this.setReady(r, "timed-out");
      }
      for (const r of this.runs.values()) {
        if (r.task?.timeoutSec && !r.task.timedOut && !r.stopping && !r.detail.endedAt && Date.now() - Date.parse(r.detail.startedAt) >= r.task.timeoutSec * 1000) {
          void this.cancelTask(r.detail.id, false, true).catch(() => this.unknown(r));
        }
      }
      if (Date.now() - this.lastDiscovery >= (this.waitingPorts() ? Math.min(500, this.scanner.intervalMs) : this.scanner.intervalMs) &&
          [...this.runs.values()].some((r) => activeStates.has(r.detail.state))) {
        this.lastDiscovery = Date.now();
        void this.refresh();
      }
    }, 250);
    const sampleSelf = () => {
      if (!this.selfSampling) this.selfSampling = this.refreshSelf().finally(() => { this.selfSampling = null; });
    };
    this.selfTimer = setInterval(sampleSelf, 2000);
    sampleSelf();
    this.saveTimer = setInterval(() => {
      if (this.dirty) this.save();
      this.pruneOperations();
    }, 500);
  }
  private waitingPorts() {
    return [...this.runs.values()].some(r => r.detail.ready?.state === "waiting" && r.readiness?.config.check.kind === "port");
  }
  private setReady(r: StoredRun, state: NonNullable<RunSummary["ready"]>["state"], evidence: NonNullable<RunSummary["ready"]>["evidence"] = null) {
    r.detail.ready = { state, at: state === "ready" || state === "timed-out" ? now() : null, afterMs: state === "ready" ? Math.max(0, Date.now() - Date.parse(r.detail.startedAt)) : null, evidence };
    this.changed(r.detail.projectId);
  }
  private checkReadyPorts(current: StoredRun[], owned: Map<string, ProcessRow[]>, ports: Map<number, import("@devpanel/contract").ListeningPort[]> | null) {
    for (const r of current) {
      if (r.detail.ready?.state !== "waiting" || !r.readiness) continue;
      const evidence = portEvidence(r.readiness.config, serviceListening(owned.get(r.detail.id) ?? [], ports));
      if (evidence) this.setReady(r, "ready", evidence);
    }
  }
  private async refreshSelf() {
    const rows = await this.scanner.toolResources();
    const at = performance.now(), cpu = process.cpuUsage();
    if (rows) {
      const daemon = resourceSample(rows.filter(p => p.pid === process.pid), this.toolPrior, at);
      const helpers = resourceSample(rows.filter(p => p.pid !== process.pid), this.toolPrior, at);
      const total = resourceSample(rows, this.toolPrior, at);
      this.selfSample = daemon;
      this.toolSample = { daemon, helpers, total };
      this.toolPrior = new Map(rows.filter(p => p.cpuMs !== null).map(p => [identity(p), { cpu: p.cpuMs!, at }]));
    } else {
      this.selfSample = {
        status: "ok", sampledAt: now(),
        cpuPercent: at > this.cpuAt ? ((cpu.user - this.cpu.user + cpu.system - this.cpu.system) / 1000 / (at - this.cpuAt)) * 100 : null,
        rssBytes: process.memoryUsage.rss(), footprintBytes: null, processCount: 1,
      };
      const unknown = { ...unavailable(), note: "原生采样不可用，无法完整统计辅助进程" };
      this.toolSample = this.scanner.recovering
        ? { daemon: this.selfSample, helpers: delayedSample(this.toolSample.helpers), total: delayedSample(this.toolSample.total) }
        : { daemon: this.selfSample, helpers: unknown, total: unknown };
      this.toolPrior.clear();
    }
    this.cpu = cpu;
    this.cpuAt = at;
  }
  allSecrets() {
    return [
      ...new Set(
        [...this.projects.values()]
          .flatMap((p) => secrets(p.config))
          .concat([...this.runs.values()].flatMap((r) => r.sensitive)),
      ),
    ];
  }
  safe<T>(v: T) {
    return redact(v, this.allSecrets());
  }
  event(event: DaemonEvent) {
    this.emit("event", this.safe(event));
  }
  info(): DaemonInfo {
    return {
      version: VERSION,
      apiVersion: 1,
      pid: process.pid,
      startedAt: this.startedAt,
      home: this.home,
      limits: this.limits,
      self: this.selfSample,
      toolResources: this.toolSample,
    };
  }
  save() {
    if (this.closed) return;
    for (const r of this.runs.values())
      r.sequenceFloor = Math.max(
        r.sequenceFloor,
        this.logs.states.get(r.detail.id)?.next ?? 1,
      );
    atomicWrite(join(this.home, "state.json"), {
      projects: [...this.projects.values()],
      runs: [...this.runs.values()],
      activity: this.activity.entries,
      policies: this.policies.settings,
      holds: this.policies.holds,
    } satisfies Disk);
    this.dirty = false;
  }
  project(pid: string) {
    const p = this.projects.get(pid);
    if (!p) throw new Fault("PROJECT_NOT_FOUND", "项目不存在", 404);
    return p;
  }
  run(rid: string) {
    const r = this.runs.get(rid);
    if (!r) throw new Fault("RUN_NOT_FOUND", "运行不存在", 404);
    return r;
  }
  operation(oid: string) {
    const op = this.operations.get(oid);
    if (!op) throw new Fault("OPERATION_NOT_FOUND", "操作不存在", 404);
    return op;
  }
  current(pid: string, sid: string) {
    return [...this.runs.values()].findLast(
      (r) =>
        r.detail.projectId === pid &&
        !r.task && r.detail.serviceId === sid &&
        activeStates.has(r.detail.state),
    );
  }
  history(pid: string, sid: string) {
    const p = this.project(pid);
    if (!p.config.services.some((s) => s.id === sid))
      throw new Fault("SERVICE_NOT_FOUND", "服务不存在", 404);
    return [...this.runs.values()]
      .filter((r) => !r.task && r.detail.projectId === pid && r.detail.serviceId === sid)
      .reverse();
  }
  summary(r: StoredRun): RunSummary {
    const d = r.detail;
    return {
      id: d.id,
      projectId: d.projectId,
      serviceId: d.serviceId,
      configRevision: d.configRevision,
      startedAt: d.startedAt,
      endedAt: d.endedAt,
      pid: d.pid,
      state: d.state,
      exit: d.exit,
      startedBy: d.startedBy ?? null,
      ready: d.ready ?? noReady(),
    };
  }
  detail(rid: string): RunDetail {
    const r = this.run(rid);
    return this.safe({
      ...r.detail,
      log: this.logs.info(rid),
      processes: r.known,
    });
  }
  view(pid: string): ProjectView {
    const p = this.project(pid);
    const services: ServiceView[] = p.config.services.map((s) => {
      const r = this.current(pid, s.id),
        last = this.history(pid, s.id)[0],
        task = this.tasks
          .get(`${pid}/${s.id}`)
          ?.find(
            (t) => !terminal(t.operation) && t.result.outcome === "pending",
          );
      return {
        id: s.id,
        name: s.name,
        hold: this.policies.hold(pid, s.id),
        locked: this.policies.get(pid).lockedServices.includes(s.id),
        state:
          r?.detail.state ??
          (last?.error?.code === "EXITED_DURING_START"
            ? "failed"
            : last?.detail.state) ??
          "idle",
        stateSince:
          r?.stateSince ??
          last?.stateSince ??
          r?.detail.startedAt ??
          last?.detail.endedAt ??
          null,
        currentRun: r ? this.summary(r) : null,
        lastRun: last ? this.summary(last) : null,
        stopTimedOut: r?.stopTimedOut ?? false,
        pendingOperationId: task?.operation.id ?? null,
        configChangedSinceStart:
          !!r &&
          // Unmigratable legacy runs have no trustworthy baseline; conservatively mark changed.
          (!r.configSnapshot ||
            canonical(r.configSnapshot) !==
              canonical(this.serviceSnapshot(p.config, s))),
        error: r?.error ?? last?.error ?? null,
      };
    });
    const states = services.map((s) => s.state),
      runningCount = states.filter((s) => s === "running").length;
    const aggregate = states.includes("unknown")
      ? "unknown"
      : runningCount === services.length
        ? "running"
        : runningCount > 0
          ? "partial"
          : states.includes("failed")
            ? "failed"
            : states.some((s) => s === "starting" || s === "stopping")
              ? "transition"
              : states.every((s) => s === "idle")
                ? "idle"
                : "stopped";
    return this.safe({
      id: p.id,
      name: p.config.name,
      root: p.config.root,
      repositories: p.config.repositories,
      mavenProjects: p.config.mavenProjects?.map(target => ({ ...target,
        currentRun: this.taskHistory(pid, { kind: "maven" }).find(r => !r.endedAt && r.maven?.mavenProjectId === target.id) ?? null,
        lastRun: this.taskHistory(pid, { kind: "maven" }).find(r => !!r.endedAt && r.maven?.mavenProjectId === target.id) ?? null,
      })),
      revision: p.revision,
      policy: this.policies.get(pid),
      aggregate,
      runningCount,
      serviceCount: services.length,
      services,
      actions: (p.config.actions || []).map(a => {
        const history = this.taskHistory(pid, { kind: "action", actionId: a.id });
        return { id: a.id, name: a.name, description: a.description ?? null,
          confirmWhenServicesRunning: a.confirmWhenServicesRunning ?? false,
          currentRun: history.find(r => !r.endedAt) ?? null, lastRun: history.find(r => !!r.endedAt) ?? null };
      }),
      maven: (p.config.mavenProjects !== undefined ? p.config.mavenProjects.length > 0 : existsSync(join(p.config.root, "pom.xml"))) ? {
        currentRun: this.taskHistory(pid, { kind: "maven" }).find(r => !r.endedAt) ?? null,
        lastRun: this.taskHistory(pid, { kind: "maven" }).find(r => !!r.endedAt) ?? null,
      } : null,
    });
  }
  changed(pid: string) {
    this.dirty = true;
    if (this.projects.has(pid))
      this.event({ type: "project.upsert", project: this.view(pid) });
  }
  getConfig(pid: string): Project {
    const p = this.project(pid);
    return { ...p, config: mask(p.config) };
  }
  private serviceSnapshot(
    config: ProjectConfig,
    service: ServiceConfig,
  ): ServiceConfig {
    const expanded = structuredClone(expandService(config, service));
    delete expanded.ready;
    return {
      ...expanded,
      cwd: resolve(config.root, service.cwd),
      env: effectiveEnv({}, expandService(config, service).env),
      stopTimeoutSec:
        service.stopTimeoutSec ?? this.limits.defaultStopTimeoutSec,
    };
  }
  validation(input: unknown) {
    return validate(input, this.base);
  }
  register(input: unknown, actor: Actor = { client: "cli", agent: null }) {
    const client = actor.client === "ui" ? "ui" : "cli";
    let existing: Project | undefined;
    if (
      input &&
      typeof input === "object" &&
      "root" in input &&
      typeof input.root === "string"
    ) {
      try {
        const root = realpathSync(input.root);
        existing = [...this.projects.values()].find(
          (p) => p.config.root === root,
        );
      } catch {}
    }
    const prepared = prepareParams(input, existing?.config, client, true);
    // Registration is a comparison, never an update: incompatible protected
    // values fall back individually to the request value for that comparison.
    if (prepared.kept.length) {
      const incoming = prepareParams(
        input,
        existing?.config,
        client,
        false,
      ).config;
      const issues = paramIssues(
        prepared.config as unknown as Record<string, unknown>,
        existing?.config,
        true,
      );
      prepared.config.params?.forEach((param, index) => {
        if (
          param &&
          prepared.kept.includes(param.key) &&
          issues.some(
            (i) =>
              i.severity === "error" && i.path === `params[${index}].value`,
          )
        )
          prepared.config.params![index] = incoming.params![index]!;
      });
    }
    input = prepared.config;
    const validation = validate(input, this.base, existing?.config, "save");
    if (!validation.ok)
      throw new Fault("CONFIG_INVALID", "配置校验失败", 422, {
        issues: validation.issues,
      });
    const config = resolveSecrets(input as ProjectConfig, existing?.config);
    if (existing) {
      if (
        canonical(comparable(existing.config)) === canonical(comparable(config))
      )
        return { created: false, project: this.getConfig(existing.id) };
      throw new Fault("CONFIG_CONFLICT", "该目录已注册，请显式更新", 409, {
        projectId: existing.id,
        revision: existing.revision,
        diff: configDiff(existing.config, config),
      });
    }
    const p: Project = {
      id: id("p"),
      revision: 1,
      createdAt: now(),
      updatedAt: now(),
      config,
    };
    this.projects.set(p.id, p);
    this.activity.config(p.id, actor, "register", 0, 1, {}, p.config);
    this.save();
    this.changed(p.id);
    return { created: true, project: this.getConfig(p.id) };
  }
  update(pid: string, input: unknown, actor: Actor = { client: "cli", agent: null }) {
    const client = actor.client === "ui" ? "ui" : "cli";
    const p = this.project(pid);
    if (
      !input ||
      typeof input !== "object" ||
      !("config" in input) ||
      !("ifRevision" in input)
    )
      throw new Fault("BAD_REQUEST", "需要 config 和 ifRevision");
    if (input.ifRevision !== p.revision)
      throw new Fault("REVISION_MISMATCH", "配置版本已变化", 409, {
        revision: p.revision,
      });
    const prepared = prepareParams(
      input.config,
      p.config,
      client,
      !("overrideUserValues" in input && input.overrideUserValues === true),
    );
    const validation = validate(prepared.config, this.base, p.config, "save");
    if (!validation.ok) {
      for (const issue of validation.issues) {
        const index = issue.path.match(/^params\[(\d+)\]\.value$/)?.[1];
        if (
          index !== undefined &&
          prepared.kept.includes(prepared.config.params![Number(index)]!.key)
        )
          issue.message +=
            "；用户值与新定义不兼容，可显式传 overrideUserValues=true 覆盖";
      }
      throw new Fault("CONFIG_INVALID", "配置校验失败", 422, {
        issues: validation.issues,
      });
    }
    const config = resolveSecrets(prepared.config, p.config);
    const duplicate = [...this.projects.values()].find(
      (x) => x.id !== pid && x.config.root === config.root,
    );
    if (duplicate)
      throw new Fault("CONFIG_CONFLICT", "该目录已注册", 409, {
        projectId: duplicate.id,
        revision: duplicate.revision,
      });
    for (const s of p.config.services)
      if (
        !config.services.some((x) => x.id === s.id) &&
        (this.current(pid, s.id) ||
          this.tasks.get(`${pid}/${s.id}`)?.some((t) => !terminal(t.operation)))
      )
        throw new Fault("PROJECT_RUNNING", "请先停止待删除的服务", 409);
    for (const a of p.config.actions || [])
      if (!config.actions?.some(x => x.id === a.id) && this.taskRunner.current(pid, { kind: "action", actionId: a.id }))
        throw new Fault("TASK_RUNNING", "请先取消待删除的快捷操作", 409);
    this.activity.config(pid, actor, "update", p.revision, p.revision + 1, p.config, config);
    p.config = config;
    this.policies.prune(pid, config.services.map(s => s.id), actor);
    p.revision++;
    p.updatedAt = now();
    this.save();
    this.changed(pid);
    return {
      ...this.getConfig(pid),
      ...(prepared.kept.length ? { keptUserValues: prepared.kept } : {}),
    };
  }
  param(
    pid: string,
    key: string | undefined,
    method: string,
    input: unknown,
    actor: Actor = { client: "cli", agent: null },
    inline = false,
  ) {
    const client = actor.client === "ui" ? "ui" : "cli";
    const project = this.project(pid);
    if (!input || typeof input !== "object" || !("ifRevision" in input))
      throw new Fault("BAD_REQUEST", "需要 ifRevision");
    if (input.ifRevision !== project.revision)
      throw new Fault("REVISION_MISMATCH", "配置版本已变化", 409, {
        revision: project.revision,
      });
    const config = structuredClone(project.config);
    config.params ??= [];
    if (method === "POST") {
      if (!("param" in input)) throw new Fault("BAD_REQUEST", "需要 param");
      const param = input.param as NonNullable<ProjectConfig["params"]>[number];
      if (config.params.some((p) => p.key === param?.key))
        throw new Fault("CONFIG_CONFLICT", "选项已存在", 409);
      config.params.push(param);
    } else {
      const param = config.params.find((p) => p.key === key);
      if (!param) throw new Fault("PARAM_UNKNOWN", "选项不存在", 404);
      if (method === "PATCH") {
        for (const field of [
          "value",
          "label",
          "description",
          "choices",
          "min",
          "max",
        ])
          if (Object.hasOwn(input, field))
            Object.assign(param, {
              [field]: (input as Record<string, unknown>)[field],
            });
      } else {
        const usedBy = uses(config, key!);
        if (usedBy.length && !inline)
          throw new Fault("PARAM_IN_USE", "选项仍被引用", 409, { usedBy });
        if (usedBy.length) inlineParam(config, key!);
        config.params = config.params.filter((p) => p.key !== key);
      }
    }
    const prepared = prepareParams(
      config,
      project.config,
      client,
      false,
    ).config;
    const issues = paramIssues(
      prepared as unknown as Record<string, unknown>,
      project.config,
      true,
    );
    if (issues.some((i) => i.severity === "error"))
      throw new Fault("CONFIG_INVALID", "选项校验失败", 422, { issues });
    // Existing root/cwd/program may have disappeared; option edits must still
    // save. This config was cloned from storage, so no root normalization or
    // unrelated environment/service validation is needed here.
    this.activity.config(pid, actor, "param", project.revision, project.revision + 1, project.config, prepared);
    project.config = prepared;
    project.revision++;
    project.updatedAt = now();
    this.save();
    this.changed(pid);
    return this.getConfig(pid);
  }

  remove(pid: string) {
    this.project(pid);
    if ([...this.runs.values()].some(r => r.task && r.detail.projectId === pid && !r.detail.endedAt))
      throw new Fault("TASK_RUNNING", "请先取消项目任务", 409);
    if (
      [...this.runs.values()].some(
        (r) => r.detail.projectId === pid && activeStates.has(r.detail.state),
      ) ||
      [...this.operations.values()].some(
        (o) => o.projectId === pid && !terminal(o),
      )
    )
      throw new Fault("PROJECT_RUNNING", "请先停止项目", 409);
    this.projects.delete(pid);
    this.policies.remove(pid);
    this.activity.entries = this.activity.entries.filter(e => e.projectId !== pid);
    for (const [rid, r] of this.runs)
      if (r.detail.projectId === pid) {
        this.runs.delete(rid);
        this.logs.delete(rid);
      }
    this.save();
    this.event({ type: "project.remove", projectId: pid });
  }
  getPolicy(pid: string) { this.project(pid); return this.policies.get(pid); }
  setPolicy(pid: string, input: unknown, actor: Actor) {
    const policy = this.policies.set(pid, input, this.project(pid).config.services.map(s => s.id), actor);
    this.save(); this.changed(pid); return policy;
  }
  releaseHold(pid: string, sid: string, actor: Actor) {
    this.policies.ui(actor);
    if (!this.project(pid).config.services.some(s => s.id === sid)) throw new Fault("SERVICE_NOT_FOUND", "服务不存在", 404);
    this.policies.release(pid, sid, actor); this.save(); this.changed(pid);
  }
  async recover() {
    const current = [...this.runs.values()].filter((r) =>
      activeStates.has(r.detail.state),
    );
    if (!current.length) return;
    let rows: Map<number, ProcessRow>;
    try {
      rows = await this.scanner.scan();
    } catch {
      for (const r of current) this.unknown(r);
      this.save();
      return;
    }
    for (const r of current) {
      if (Math.abs(r.boot - this.boot) > 5) {
        r.known = [];
        this.finish(r, "daemon-lost", null, null, "stopped");
        continue;
      }
      const live = discover(r.known, r.detail.pid, rows);
      if (live.length) {
        r.known = live.map(publicProcess);
        this.unknown(r);
        this.sys(r, "管理服务重启，旧管道无法接续；请停止此运行后重新启动");
      } else if (r.known.length && !r.known.some((p) => rows.has(p.pid))) {
        r.known = [];
        this.finish(r, "daemon-lost", null, null, "failed");
      } else this.unknown(r);
    }
    this.save();
  }
  unknown(r: StoredRun) {
    if (r.detail.ready?.state === "waiting") this.setReady(r, "unknown");
    r.detail.state = "unknown";
    r.stopTimedOut = false;
    r.stateSince = now();
    r.error = {
      code: "STATE_UNVERIFIABLE",
      message: "无法完整核验运行或接续日志，禁止重复启动",
    };
    this.changed(r.detail.projectId);
  }
  private sys(r: StoredRun, text: string) {
    this.logs.add(r.detail.id, "sys", redact(text, r.sensitive, 1));
  }
  private finish(
    r: StoredRun,
    reason: NonNullable<RunSummary["exit"]>["reason"],
    code: number | null,
    signal: string | null,
    state: RunSummary["state"],
  ) {
    reason = r.task?.timedOut ? "timeout" : reason;
    r.detail.state = state;
    if (r.detail.ready?.state === "waiting") this.setReady(r, "ended-before-ready");
    r.detail.endedAt = now();
    r.stateSince = r.detail.endedAt;
    r.detail.exit = { reason, code, signal, at: r.detail.endedAt, requestedBy: ["user-stop", "force-stop", "start-cancelled"].includes(reason) ? r.requestedBy ?? daemonActor : null };
    if (r.task) this.activity.add(r.detail.projectId, r.detail.startedBy ?? daemonActor, { kind: "task-run", runId: r.detail.id, taskKind: r.task.target.kind, label: r.task.label, state: this.taskSummary(r).state });
    r.known = [];
    r.detail.processes = [];
    r.stopTimedOut = false;
    if (reason !== "spawn-failed") r.error = null;
    this.sys(
      r,
      `进程已退出 · ${reason} · code=${code ?? "未知"} · signal=${signal ?? "无"}`,
    );
    this.children.delete(r.detail.id);
    this.changed(r.detail.projectId);
    this.invalidateStats();
  }
  private invalidateStats() {
    if (
      ![...this.runs.values()].some((r) => activeStates.has(r.detail.state))
    ) {
      this.stats = {
        sampledAt: now(),
        intervalMs: this.limits.statsIntervalMs,
        projects: {},
      };
      this.prior.clear();
      this.event({ type: "stats", stats: this.stats });
    }
  }
  async refresh() {
    if (this.scanning) return this.scanning;
    this.scanning = this.refreshOnce().finally(() => {
      this.scanning = null;
    });
    return this.scanning;
  }
  private async refreshOnce() {
    const current = [...this.runs.values()].filter(
      (r) => activeStates.has(r.detail.state) && r.detail.pid !== null,
    );
    if (!current.length) return;
    let rows: Map<number, ProcessRow>;
    try {
      rows = await this.scanner.scan();
    } catch {
      const projects: Record<string, ProjectStats> = {};
      for (const r of current) {
        const p = (projects[r.detail.projectId] ??= {
          total: unavailable(),
          services: {}, tasks: {},
        });
        const key = r.task ? r.detail.id : r.detail.serviceId;
        const previous = this.stats?.projects[r.detail.projectId];
        const previousSample = (r.task ? previous?.tasks : previous?.services)?.[key];
        const sample = this.scanner.recovering
          ? delayedSample(previousSample?.runId === r.detail.id ? previousSample : unavailable())
          : unavailable();
        (r.task ? p.tasks : p.services)[key] = {
          ...sample,
          runId: r.detail.id,
          listening: null,
        };
        if (this.scanner.recovering) p.total = delayedSample(unavailable());
      }
      this.stats = {
        sampledAt: now(),
        intervalMs: this.limits.statsIntervalMs,
        projects,
      };
      this.event({ type: "stats", stats: this.stats });
      return;
    }
    const owned = new Map<string, ProcessRow[]>();
    for (const r of current) {
      // The child spawn handshake installs root identity before periodic discovery may act.
      if (
        !r.known.length &&
        r.detail.state === "starting" &&
        this.children.has(r.detail.id)
      )
        continue;
      const live = discover(r.known, r.detail.pid, rows);
      owned.set(r.detail.id, live);
      const child = this.children.get(r.detail.id);
      if (
        !live.length &&
        child &&
        child.exitCode === null &&
        child.signalCode === null &&
        !r.rootExit
      ) {
        // A missing observation is not evidence that our live child exited.
        // Preserve its identity and block duplicate starts until it can be verified.
        if (r.detail.state !== "unknown") this.unknown(r);
        continue;
      }
      const changed = canonical(r.known) !== canonical(live.map(publicProcess));
      r.known = live.map(publicProcess);
      if (changed) this.dirty = true;
      if (!live.length && (r.detail.state !== "unknown" || r.rootExit)) {
        const root = this.children.get(r.detail.id);
        if (
          root &&
          root.exitCode === null &&
          root.signalCode === null &&
          !r.rootExit
        )
          continue;
        const exit = r.rootExit;
        this.finish(
          r,
          r.stopping
            ? r.detail.exit?.reason === "force-stop"
              ? "force-stop"
              : "user-stop"
            : "self-exit",
          exit?.code ?? null,
          exit?.signal ?? null,
          r.stopping ? "stopped" : exit?.code === 0 ? "exited" : "failed",
        );
      }
    }
    const at = Date.now();
    if (at - this.lastStats < this.limits.statsIntervalMs && this.waitingPorts() && at - this.lastReadyPorts >= 500) {
      const waiting = current.filter(r => r.detail.ready?.state === "waiting" && r.readiness?.config.check.kind === "port");
      const ports = await this.scanner.listening(waiting.flatMap(r => owned.get(r.detail.id) ?? []));
      this.checkReadyPorts(waiting, owned, ports); this.lastReadyPorts = at;
    }
    if (at - this.lastStats >= this.limits.statsIntervalMs) {
      // Resource syscalls touch only verified managed processes, at the publish interval.
      const sampled = await this.scanner.resources([...owned.values()].flat());
      const byIdentity = new Map(sampled.map(p => [identity(p), p]));
      for (const [runId, live] of owned) owned.set(runId, live.map(p => byIdentity.get(identity(p))!));
      const ports = await this.scanner.listening([...owned.values()].flat());
      this.checkReadyPorts(current, owned, ports); this.lastReadyPorts = at;
      const projects: Record<string, ProjectStats> = {},
        projectRows = new Map<string, Map<string, ProcessRow>>();
      for (const r of current) {
        if (!activeStates.has(r.detail.state)) continue;
        const live = owned.get(r.detail.id) || [];
        const p = (projects[r.detail.projectId] ??= {
          total: unavailable(),
          services: {}, tasks: {},
        });
        const sample = resourceSample(live, this.prior, at);
        if (r.detail.state === "unknown" && sample.status === "ok") {
          sample.status = "partial";
          sample.note = "日志采集已中断，进程范围可能不完整";
        }
        (r.task ? p.tasks : p.services)[r.task ? r.detail.id : r.detail.serviceId] = {
          ...sample,
          runId: r.detail.id,
          listening: serviceListening(live, ports),
        };
        let dedup = projectRows.get(r.detail.projectId);
        if (!dedup) {
          dedup = new Map();
          projectRows.set(r.detail.projectId, dedup);
        }
        for (const row of live) dedup.set(identity(row), row);
      }
      for (const [pid, p] of Object.entries(projects)) {
        p.total = resourceSample(
          [...projectRows.get(pid)!.values()],
          this.prior,
          at,
        );
        if (
          [...Object.values(p.services), ...Object.values(p.tasks)].some(
            (s) => s.status === "partial" || s.status === "unavailable",
          ) &&
          p.total.status === "ok"
        ) {
          p.total.status = "partial";
          p.total.note = "部分服务数据不完整";
        }
      }
      const next = new Map<string, { cpu: number; at: number }>();
      for (const list of owned.values())
        for (const row of list)
          if (row.cpuMs !== null) next.set(identity(row), { cpu: row.cpuMs, at });
      this.prior = next;
      this.lastStats = at;
      this.stats = {
        sampledAt: now(),
        intervalMs: this.limits.statsIntervalMs,
        projects,
      };
      this.event({ type: "stats", stats: this.stats });
    }
  }
  projectStats(pid: string): ProjectStats {
    this.project(pid);
    const p = this.stats?.projects[pid];
    const services: ProjectStats["services"] = {};
    for (const s of this.project(pid).config.services) {
      const r = this.current(pid, s.id);
      if (r)
        services[s.id] =
          p?.services[s.id]?.runId === r.detail.id
            ? p.services[s.id]!
            : {
                ...unavailable(),
                status: "sampling",
                runId: r.detail.id,
                listening: null,
              };
    }
    const tasks: ProjectStats["tasks"] = {};
    for (const r of this.runs.values()) if (r.task && r.detail.projectId === pid && !r.detail.endedAt)
      tasks[r.detail.id] = p?.tasks[r.detail.id] ?? { ...unavailable(), status: "sampling", runId: r.detail.id, listening: null };
    const coherent =
      Object.keys(tasks).length === Object.keys(p?.tasks || {}).length &&
      Object.keys(tasks).every(rid => p?.tasks[rid]?.runId === rid) &&
      !!p &&
      Object.keys(services).length === Object.keys(p.services).length &&
      Object.entries(services).every(
        ([sid, sample]) => p.services[sid]?.runId === sample.runId,
      );
    return Object.keys(services).length + Object.keys(tasks).length
      ? {
          total: coherent ? p.total : { ...unavailable(), status: "sampling" },
          services, tasks,
        }
      : { total: unavailable(), services: {}, tasks: {} };
  }
  submit(input: unknown, actor: Actor = { client: "cli", agent: null }, bypassPolicy = false): Operation {
    const source = actor.client;
    if (!input || typeof input !== "object")
      throw new Fault("BAD_REQUEST", "操作请求无效");
    const req = input as ActionRequest;
    if (
      !["start", "stop", "restart", "force-stop"].includes(req.action) ||
      typeof req.projectId !== "string"
    )
      throw new Fault("BAD_REQUEST", "操作类型或项目 ID 无效");
    if (this.shuttingDown && ["start", "restart"].includes(req.action))
      throw new Fault(
        "PROJECT_RUNNING",
        "管理服务正在停止，暂不接受新的启动请求",
        409,
      );
    if (req.overrideHold !== undefined && typeof req.overrideHold !== "boolean") throw new Fault("BAD_REQUEST", "overrideHold 必须为布尔值");
    const p = this.project(req.projectId);
    if (
      req.serviceIds !== undefined &&
      (!Array.isArray(req.serviceIds) ||
        !req.serviceIds.length ||
        !req.serviceIds.every((s) => typeof s === "string") ||
        new Set(req.serviceIds).size !== req.serviceIds.length)
    )
      throw new Fault("BAD_REQUEST", "serviceIds 必须是非空且不重复的 ID 数组");
    const serviceIds = req.serviceIds ?? p.config.services.map((s) => s.id);
    for (const sid of serviceIds)
      if (!p.config.services.some((s) => s.id === sid))
        throw new Fault("SERVICE_NOT_FOUND", "服务不存在", 404);
    const op: Operation = {
      id: id("op"),
      projectId: p.id,
      action: req.action,
      serviceIds,
      source, actor,
      state: "queued",
      createdAt: now(),
      finishedAt: null,
      results: serviceIds.map((serviceId) => ({
        serviceId,
        outcome: "pending",
        runId: null,
        error: null,
      })),
      cancelledBy: null,
    };
    this.operations.set(op.id, op);
    const jobs: Promise<void>[] = [];
    for (const result of op.results) {
      // Denied stops never enter the queue and therefore never cancel queued starts.
      const denied = bypassPolicy ? null : this.policies.denial(p.id, result.serviceId, req.action, actor, req.overrideHold === true);
      if (denied) { result.outcome = "failed"; result.error = denied; continue; }
      const key = `${p.id}/${result.serviceId}`,
        list = this.tasks.get(key) ?? [];
      if (req.action === "stop" || req.action === "force-stop")
        for (const task of list)
          if (
            ["start", "restart"].includes(task.operation.action) &&
            task.result.outcome === "pending"
          ) {
            task.cancelled = true;
            task.cancelledByActor = actor;
            const run = task.result.runId ? this.runs.get(task.result.runId) : undefined;
            if (run) run.requestedBy = actor;
            task.operation.cancelledBy = op.id;
          }
      const task: ManagedOperation = { operation: op, result, cancelled: false };
      list.push(task);
      this.tasks.set(key, list);
      const queued = (this.queues.get(key) ?? Promise.resolve()).then(
        async () => {
          op.state = "running";
          this.event({ type: "operation", operation: op });
          this.changed(p.id);
          try {
            if (task.cancelled) {
              result.outcome = "cancelled";
              return;
            }
            // A UI stop may have established a hold while this start was waiting.
            const denied = bypassPolicy ? null : this.policies.denial(p.id, result.serviceId, req.action, actor, req.overrideHold === true);
            if (denied) { result.outcome = "failed"; result.error = denied; return; }
            if (req.action === "start") await this.start(task);
            else if (req.action === "restart") {
              await this.stop(task, false);
              if (task.cancelled) {
                result.outcome = "cancelled";
                return;
              }
              if (
                result.outcome === "stopped" ||
                result.outcome === "already-stopped"
              ) {
                result.outcome = "pending";
                await this.start(task);
              } else if (result.outcome === "stop-timeout")
                result.outcome = "failed";
            } else await this.stop(task, req.action === "force-stop");
          } catch (e) {
            result.outcome = "failed";
            result.error =
              e instanceof Fault
                ? e.error
                : { code: "INTERNAL", message: "操作失败，请检查本地运行环境" };
          } finally {
            if (task.cancelled) result.outcome = "cancelled";
            if (!bypassPolicy) this.policies.outcome(op, result, actor, req.overrideHold === true);
            this.changed(p.id);
          }
        },
      );
      this.queues.set(key, queued);
      jobs.push(
        queued.finally(() => {
          const pending = (this.tasks.get(key) || []).filter((t) => t !== task);
          if (pending.length) this.tasks.set(key, pending);
          else this.tasks.delete(key);
          if (this.queues.get(key) === queued) this.queues.delete(key);
        }),
      );
    }
    void Promise.all(jobs).then(() => {
      const outcomes = op.results.map((r) => r.outcome),
        success = outcomes.filter((o) =>
          ["started", "already-running", "stopped", "already-stopped"].includes(
            o,
          ),
        ).length;
      op.state = outcomes.every((o) => o === "cancelled")
        ? "cancelled"
        : success === outcomes.length
          ? "succeeded"
          : success > 0
            ? "partial"
            : "failed";
      op.finishedAt = now();
      this.activity.add(p.id, actor, { kind: "operation", operationId: op.id, action: op.action, serviceIds: op.serviceIds, state: op.state, ...(this.policies.overridden.delete(op.id) ? { overrideHold: true } : {}), results: op.results.map(r => ({ serviceId: r.serviceId, outcome: r.outcome, runId: r.runId, errorCode: r.error?.code ?? null })) });
      this.event({ type: "operation", operation: op });
      this.changed(p.id);
      this.save();
    });
    this.event({ type: "operation", operation: op });
    this.changed(p.id);
    return op;
  }
  async start(task: ManagedOperation, definition?: ActionConfig, metadata?: TaskMetadata) {
    const { operation: op, result } = task,
      p = this.project(op.projectId),
      s = definition ?? p.config.services.find((s) => s.id === result.serviceId)!;
    const current = metadata ? this.taskRunner.current(p.id, metadata.target) : this.current(p.id, s.id);
    if (current) {
      result.runId = current.detail.id;
      if (["starting", "running"].includes(current.detail.state)) {
        result.outcome = "already-running";
        return;
      }
      throw new Fault(
        "STATE_UNVERIFIABLE",
        "旧运行尚未停止，不能创建新实例",
        409,
      );
    }
    const expanded = expandService(p.config, s);
    const rid = id("r"),
      env = effectiveEnv(this.base, expanded.env),
      cwd = resolve(p.config.root, s.cwd);
    const r: StoredRun = {
      task: metadata,
      ...(!metadata && "ready" in s && s.ready ? { readiness: { config: readySnapshot(p.config, s.ready)!, seq: 0, tails: {} } } : {}),
      configSnapshot: this.serviceSnapshot(p.config, s),
      detail: {
        id: rid,
        projectId: p.id,
        serviceId: s.id,
        configRevision: p.revision,
        startedAt: now(),
        startedBy: op.actor ?? daemonActor,
        endedAt: null,
        pid: null,
        state: "starting",
        exit: null,
        ready: !metadata && "ready" in s && s.ready ? { ...noReady(), state: "waiting" } : noReady(),
        command: expandService(p.config, s, true).command,
        params: Object.fromEntries(
          serviceParams(p.config, s).map((p) => [
            p.key,
            p.secret ? { secret: true } : p.value!,
          ]),
        ),
        cwd,
        envKeys: Object.keys(env),
        log: { firstSeq: null, lastSeq: null, bytes: 0, truncated: false },
        processes: [],
      },
      known: [],
      stopping: false,
      stopTimedOut: false,
      error: null,
      rootExit: null,
      sequenceFloor: 1,
      sensitive: secrets(p.config),
      boot: this.boot,
    };
    this.runs.set(rid, r);
    this.logs.create(rid, 1, metadata ? this.limits.logBytesPerTaskRun : this.limits.logBytesPerRun);
    result.runId = rid;
    this.retention(p.id, s.id, metadata?.target);
    this.save();
    this.changed(p.id);
    const validation = validate(
      { ...p.config, services: [{ ...s, id: "run" }], actions: [] },
      this.base,
      p.config,
      "save",
    );
    const error = validation.issues.find((i) => i.severity === "error");
    if (error) {
      r.error = {
        code:
          error.code === "COMMAND_NOT_FOUND"
            ? "COMMAND_NOT_FOUND"
            : "CWD_UNAVAILABLE",
        message: error.message,
      };
      this.finish(r, "spawn-failed", null, null, "failed");
      result.outcome = "failed";
      result.error = r.error;
      return;
    }
    if (task.cancelled) {
      r.requestedBy = task.cancelledByActor ?? daemonActor;
      this.finish(r, "start-cancelled", null, null, "stopped");
      result.outcome = "cancelled";
      return;
    }
    void this.scanner.prepare();
    const program = findProgram(expanded.command[0]!, cwd, env.PATH || "")!;
    const child = spawn(program, expanded.command.slice(1), {
      cwd,
      env,
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    this.children.set(rid, child);
    const out = this.logs.collector(rid, "out", r.sensitive),
      err = this.logs.collector(rid, "err", r.sensitive);
    child
      .stdout!.on("data", out.write)
      .on("end", out.end)
      .on("close", out.end)
      .on("error", () =>
        this.emit("gap", { runId: rid, reason: "stdout 管道中断" }),
      );
    child
      .stderr!.on("data", err.write)
      .on("end", err.end)
      .on("close", err.end)
      .on("error", () =>
        this.emit("gap", { runId: rid, reason: "stderr 管道中断" }),
      );
    child.on("exit", (code, signal) => {
      r.rootExit = { code, signal };
      void this.refresh();
    });
    const spawned = await new Promise<boolean>((res) => {
      child.once("spawn", () => res(true));
      child.once("error", () => res(false));
    });
    if (!spawned) {
      r.error = {
        code: "SPAWN_FAILED",
        message: "无法创建进程，请检查程序及工作目录",
      };
      this.finish(r, "spawn-failed", null, null, "failed");
      result.outcome = "failed";
      result.error = r.error;
      return;
    }
    r.detail.pid = child.pid!;
    try {
      const rows = await this.scanner.scan(),
        root = rows.get(child.pid!);
      if (root) {
        r.known = discover([publicProcess(root)], root.pid, rows).map(
          publicProcess,
        );
      } else if (!r.rootExit) {
        this.unknown(r);
      }
    } catch {
      this.unknown(r);
    }
    this.sys(
      r,
      `已启动 · 运行 ${rid} · PID ${child.pid} · ${r.detail.command.join(" ")}`,
    );
    this.save();
    if (metadata) {
      if (!r.detail.endedAt && r.detail.state === "starting") r.detail.state = "running";
      await this.refresh();
      this.changed(p.id);
      this.save();
      return;
    }
    const until = Date.now() + this.limits.startGraceMs;
    while (
      Date.now() < until &&
      !task.cancelled &&
      !r.rootExit &&
      r.detail.state === "starting"
    )
      await sleep(25);
    await this.refresh();
    // A shared scan may have observed the root before its exit event arrived
    // while socket IO was pending. Recheck survivors before declaring start.
    if (r.rootExit && r.known.length) await this.refresh();
    if (task.cancelled) {
      result.outcome = "cancelled";
      return;
    }
    if (r.rootExit && !r.known.length) {
      if (!r.detail.endedAt)
        this.finish(
          r,
          "self-exit",
          r.rootExit.code,
          r.rootExit.signal,
          r.rootExit.code === 0 ? "exited" : "failed",
        );
      r.error = {
        code: "EXITED_DURING_START",
        message: "程序在启动观察期内退出",
      };
      result.outcome = "failed";
      result.error = r.error;
    } else if (r.detail.state === "unknown") {
      result.outcome = "failed";
      result.error = r.error;
    } else if (activeStates.has(r.detail.state)) {
      r.detail.state = "running";
      r.stateSince = now();
      result.outcome = "started";
    } else {
      result.outcome = "failed";
      result.error = {
        code: "EXITED_DURING_START",
        message: "程序在启动观察期内退出",
      };
    }
    this.changed(p.id);
    this.save();
  }
  async stop(task: ManagedOperation, force: boolean, timeout = false, taskRun?: StoredRun) {
    const { operation: op, result } = task,
      r = taskRun ?? this.current(op.projectId, result.serviceId);
    if (!r) {
      result.outcome = "already-stopped";
      return;
    }
    result.runId = r.detail.id;
    const rows = await this.scanner.scan(),
      live = discover(r.known, r.detail.pid, rows);
    if (r.detail.endedAt) { result.outcome = "stopped"; return; }
    if (r.detail.state === "unknown" && !live.length)
      throw new Fault("STATE_UNVERIFIABLE", "无法核验旧运行，未发送信号", 409);
    // A delayed deadline callback / scan is not evidence that a process was timed out.
    // ChildProcess may already know the root exited even if the snapshot still contains it.
    const child = this.children.get(r.detail.id);
    const survivors = live.filter(p => p.pid !== r.detail.pid || !(r.rootExit || child && (child.exitCode !== null || child.signalCode !== null)));
    if (timeout && !survivors.length) {
      await this.refresh();
      result.outcome = r.detail.endedAt ? "already-stopped" : "pending";
      return;
    }
    r.known = (timeout ? survivors : live).map(publicProcess);
    if (timeout && r.task) r.task.timedOut = true;
    r.requestedBy = timeout ? null : op.actor ?? daemonActor;
    r.stopping = true;
    r.detail.state = "stopping";
    r.stateSince = now();
    r.stopTimedOut = false;
    r.error = null;
    if (force)
      r.detail.exit = {
        reason: "force-stop",
        requestedBy: r.requestedBy,
        code: null,
        signal: null,
        at: now(),
      };
    this.changed(op.projectId);
    this.sys(
      r,
      `发送 ${force ? "SIGKILL" : "SIGTERM"} · ${live.length} 个身份已核验进程`,
    );
    this.save();
    verifiedSignal(r.known, rows, force ? "SIGKILL" : "SIGTERM");
    const signalled = new Set(r.known.map(identity));
    const s = this.project(op.projectId).config.services.find(
      (s) => s.id === result.serviceId,
    )!;
    const timeoutSec = force
      ? 5
      : (r.configSnapshot?.stopTimeoutSec ??
        s?.stopTimeoutSec ??
        this.limits.defaultStopTimeoutSec);
    const until = Date.now() + timeoutSec * 1000;
    while (Date.now() < until) {
      await this.refresh();
      if (!activeStates.has(r.detail.state)) {
        result.outcome = "stopped";
        return;
      }
      // Re-discover descendants created during shutdown and verify immediately before signaling.
      const snapshot = await this.scanner.scan();
      const descendants = discover(r.known, r.detail.pid, snapshot);
      r.known = descendants.map(publicProcess);
      const newlyFound = r.known.filter((p) => !signalled.has(identity(p)));
      verifiedSignal(newlyFound, snapshot, force ? "SIGKILL" : "SIGTERM");
      for (const p of newlyFound) signalled.add(identity(p));
      if (!descendants.length) {
        this.finish(
          r,
          force ? "force-stop" : "user-stop",
          r.rootExit?.code ?? null,
          r.rootExit?.signal ?? null,
          "stopped",
        );
        result.outcome = "stopped";
        return;
      }
      if (task.cancelled) {
        result.outcome = "cancelled";
        return;
      }
      await sleep(100);
    }
    // Recheck at the deadline: stats and the pre-sleep observation may be stale.
    const remaining = discover(r.known, r.detail.pid, await this.scanner.scan());
    r.known = remaining.map(publicProcess);
    if (!remaining.length) {
      this.finish(
        r,
        force ? "force-stop" : "user-stop",
        r.rootExit?.code ?? null,
        r.rootExit?.signal ?? null,
        "stopped",
      );
      result.outcome = "stopped";
      return;
    }
    r.stopTimedOut = true;
    r.error = {
      code: "STOP_TIMEOUT",
      message: "进程仍在运行，尚未停止",
      details: { timeoutSec, remaining: remaining.length },
    };
    result.outcome = "stop-timeout";
    result.error = r.error;
    this.sys(r, "停止超时，进程仍在跟踪");
    this.changed(op.projectId);
    this.save();
  }
  private retention(pid: string, sid: string, target?: TaskTarget) {
    const history = [...this.runs.values()].filter(r => r.detail.projectId === pid && (target ? r.task && this.taskRunner.matches(r.task.target, target) : !r.task && r.detail.serviceId === sid)).reverse();
    for (const r of history.slice(history[0]?.task ? this.limits.taskRunsKept : this.limits.runsKeptPerService))
      if (!activeStates.has(r.detail.state)) {
        this.runs.delete(r.detail.id);
        this.logs.delete(r.detail.id);
      }
  }
  taskSummary(r: StoredRun) { return this.taskRunner.summary(r); }
  taskDetail(rid: string) { return this.taskRunner.detail(rid); }
  private gitClient?: Promise<Git>;
  get git() { return this.gitClient ??= import("./git.ts").then(({ Git }) => new Git(this.base, () => this.scanner.scan())); }
  private mavenModels?: Promise<MavenModels>;
  async mavenModel(pid: string, reload = false, mavenProjectId?: string) {
    const project = this.project(pid);
    const models = await (this.mavenModels ??= import("./maven.ts").then(({ MavenModels }) => new MavenModels()));
    return this.safe(models.read(mavenTarget(project.config, mavenProjectId).config, this.base, reload));
  }
  startMaven(pid: string, input: unknown, actor: Actor = { client: "cli", agent: null }) { return this.taskRunner.startMaven(pid, input, actor); }
  startAction(pid: string, aid: string, actor: Actor = { client: "cli", agent: null }) { return this.taskRunner.startAction(pid, aid, actor); }
  taskHistory(pid: string, target: TaskTarget) { return this.taskRunner.history(pid, target); }
  cancelTask(rid: string, force: boolean, timeout = false, actor: Actor = daemonActor) { return this.taskRunner.cancel(rid, force, timeout, actor); }
  stopAllTasks() { return this.taskRunner.stopAll(); }
  private pruneOperations() {
    for (const [id, op] of this.operations)
      if (
        op.finishedAt &&
        Date.now() - Date.parse(op.finishedAt) > 10 * 60 * 1000
      )
        this.operations.delete(id);
  }
  async close() {
    this.shuttingDown = true;
    await (await this.gitClient)?.close();
    clearInterval(this.timer);
    clearInterval(this.selfTimer);
    clearInterval(this.saveTimer);
    if (this.scanning) await this.scanning;
    if (this.selfSampling) await this.selfSampling;
    this.scanner.close();
    await this.logs.close();
    this.save();
    this.closed = true;
  }
}
