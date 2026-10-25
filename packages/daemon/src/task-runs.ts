import { mavenTarget } from "./project-targets.ts";
import type { Actor, ClientKind, MavenRunRequest, ActionConfig, TaskRunSummary, TaskRunDetail, StartTaskRunResponse, Operation, OperationTargetResult } from "@devpanel/contract";
import type { Manager, StoredRun } from "./manager.ts";
import { daemonActor } from "./activity.ts";
import { Fault, id, now, sleep } from "./storage.ts";
export type TaskTarget = { kind: "action"; actionId: string } | { kind: "maven" };
export interface TaskMetadata {
  target: { kind: "action"; actionId: string } | { kind: "maven"; request: MavenRunRequest };
  label: string;
  source: ClientKind;
  actor?: Actor;
  timeoutSec?: number;
  timedOut?: boolean;
}
/** Task identity, history and scheduling; Manager owns shared process / log mechanics. */
export class TaskRuns {
  private taskStarts = new Map<string, Promise<StartTaskRunResponse>>();
  private taskCancels = new Map<string, Promise<void>>();
  private readonly host: Manager;
  constructor(host: Manager) { this.host = host; }
  matches(a: TaskTarget, b: TaskTarget) { return a.kind === b.kind && (a.kind !== "action" || b.kind === "action" && a.actionId === b.actionId); }
  current(pid: string, target: TaskTarget) {
    return [...this.host.runs.values()].findLast(r => r.task && r.detail.projectId === pid && !r.detail.endedAt && this.matches(r.task.target, target));
  }
  summary(r: StoredRun): TaskRunSummary {
    if (!r.task) throw new Fault("RUN_NOT_FOUND", "任务运行不存在", 404);
    const d = r.detail;
    const state: TaskRunSummary["state"] = !d.endedAt
      ? d.state === "unknown" ? "unknown" : r.stopping ? "cancelling" : "running"
      : d.exit?.reason === "timeout" ? "timed-out"
      : ["user-stop", "force-stop", "start-cancelled"].includes(d.exit?.reason || "") ? "cancelled"
      : d.exit?.reason === "self-exit" && d.exit.code === 0 ? "succeeded" : "failed";
    return this.host.safe({ id: d.id, projectId: d.projectId, kind: r.task.target.kind, actionId: r.task.target.kind === "action" ? r.task.target.actionId : null,
      maven: r.task.target.kind === "maven" ? r.task.target.request : null, label: r.task.label, source: r.task.source, configRevision: d.configRevision,
      startedAt: d.startedAt, endedAt: d.endedAt, pid: d.pid, state, exit: d.exit, startedBy: d.startedBy ?? null, cancelTimedOut: r.stopTimedOut });
  }
  detail(rid: string): TaskRunDetail {
    const d = this.host.detail(rid);
    return { ...this.summary(this.host.run(rid)), command: d.command, cwd: d.cwd, envKeys: d.envKeys,
      params: d.params, log: d.log, processes: d.processes };
  }
  async startMaven(pid: string, input: unknown, actor: Actor) {
    const source = actor.client === "ui" ? "ui" : "cli";
    const rawId = input && typeof input === "object" ? (input as Record<string, unknown>).mavenProjectId : undefined;
    if (rawId !== undefined && typeof rawId !== "string") throw new Fault("MAVEN_INVALID", "mavenProjectId 必须为字符串", 422);
    const target = mavenTarget(this.host.project(pid).config, rawId as string | undefined);
    const model = await this.host.mavenModel(pid, false, target.target?.id);
    const { mavenCommand } = await import("./maven.ts");
    const { request, command } = mavenCommand(input, model);
    if (target.target) request.mavenProjectId = target.target.id;
    const label = `${request.goals.join(" ")} · ${target.target?.name ?? request.moduleId}`;
    return this.startTask(pid, { id: "maven", name: label, cwd: target.target?.path ?? ".", command }, { target: { kind: "maven", request }, label, source, actor });
  }
  history(pid: string, target: TaskTarget): TaskRunSummary[] {
    const p = this.host.project(pid);
    if (target.kind === "action" && !p.config.actions?.some(a => a.id === target.actionId))
      throw new Fault("ACTION_NOT_FOUND", "快捷操作不存在", 404);
    return [...this.host.runs.values()].filter(r => r.task && r.detail.projectId === pid && this.matches(r.task.target, target))
      .reverse().map(r => this.summary(r));
  }
  async startAction(pid: string, aid: string, actor: Actor) {
    const source = actor.client === "ui" ? "ui" : "cli";
    const a = this.host.project(pid).config.actions?.find(a => a.id === aid);
    if (!a) throw new Fault("ACTION_NOT_FOUND", "快捷操作不存在", 404);
    return this.startTask(pid, a, {
      target: { kind: "action", actionId: aid }, label: a.name, source, actor, timeoutSec: a.timeoutSec,
    });
  }
  async startTask(pid: string, definition: ActionConfig, metadata: TaskMetadata): Promise<StartTaskRunResponse> {
    if (this.host.shuttingDown) throw new Fault("TASK_RUNNING", "管理服务正在停止", 409);
    const key = JSON.stringify(metadata.target.kind === "action" ? [pid, "action", metadata.target.actionId] : [pid, "maven"]);
    const pending = this.taskStarts.get(key);
    if (pending) await pending;
    const current = this.current(pid, metadata.target);
    if (current) {
      if (metadata.target.kind === "maven") throw new Fault("TASK_RUNNING", "项目已有 Maven 运行", 409, { runId: current.detail.id });
      return { created: false, run: this.summary(current) };
    }
    const result: OperationTargetResult = { serviceId: definition.id, outcome: "pending", runId: null, error: null };
    const operation: Operation = { id: id("op"), projectId: pid, action: "start", serviceIds: [definition.id],
      source: metadata.source, actor: metadata.actor ?? { client: metadata.source, agent: null }, state: "running", createdAt: now(), finishedAt: null, results: [result], cancelledBy: null };
    const job = (async () => {
      await this.host.start({ operation, result, cancelled: false }, definition, metadata);
      return { created: true, run: this.summary(this.host.run(result.runId!)) };
    })();
    this.taskStarts.set(key, job);
    try { return await job; } finally { if (this.taskStarts.get(key) === job) this.taskStarts.delete(key); }
  }
  async cancel(rid: string, force: boolean, timeout = false, actor: Actor = daemonActor): Promise<TaskRunSummary> {
    const r = this.host.run(rid);
    this.summary(r);
    if (r.detail.endedAt) return this.summary(r);
    const key = `${rid}/${force}`;
    if (!this.taskCancels.has(key)) {
      const result: OperationTargetResult = { serviceId: r.detail.serviceId, outcome: "pending", runId: rid, error: null };
      const operation: Operation = { id: id("op"), projectId: r.detail.projectId, action: force ? "force-stop" : "stop",
        serviceIds: [r.detail.serviceId], source: actor.client, actor, state: "running", createdAt: now(), finishedAt: null, results: [result], cancelledBy: null };
      const job = this.host.stop({ operation, result, cancelled: false }, force, timeout, r).catch(() => {
        if (!r.detail.endedAt) this.host.unknown(r);
      }).finally(() => this.taskCancels.delete(key));
      this.taskCancels.set(key, job);
      // stop() performs identity verification asynchronously; publish cancelling only after it succeeds.
      await Promise.race([job, sleep(20)]);
    }
    return this.summary(r);
  }
  async stopAll() {
    await Promise.allSettled(this.taskStarts.values());
    const running = [...this.host.runs.values()].filter(r => r.task && !r.detail.endedAt);
    for (const r of running) await this.cancel(r.detail.id, false);
    await Promise.all(this.taskCancels.values());
    if (running.some(r => !r.detail.endedAt)) throw new Fault("TASK_RUNNING", "仍有任务未取消，请先处理任务", 409);
  }
}
