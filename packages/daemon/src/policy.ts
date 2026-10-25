import type {
  Actor,
  ProjectPolicy,
  ServiceHold,
  ActionKind,
  Operation,
  OperationTargetResult,
} from "@devpanel/contract";
import { Fault, now } from "./storage.ts";
import type { Activities } from "./activity.ts";
export const defaultPolicy = (): ProjectPolicy => ({
  holdAfterUserStop: true,
  agentForceStop: "deny",
  lockedServices: [],
});
/** Supervision state is deliberately separate from imported project configuration. */
export class Policies {
  settings: Record<string, ProjectPolicy>;
  holds: Record<string, Record<string, ServiceHold>>;
  readonly activity: Activities;
  readonly overridden = new Set<string>();
  constructor(
    activity: Activities,
    settings: Record<string, ProjectPolicy> = {},
    holds: Record<string, Record<string, ServiceHold>> = {},
  ) {
    this.activity = activity;
    this.settings = settings;
    this.holds = holds;
  }
  get(pid: string): ProjectPolicy {
    return structuredClone(this.settings[pid] ?? defaultPolicy());
  }
  hold(pid: string, sid: string) {
    return this.holds[pid]?.[sid] ?? null;
  }
  set(pid: string, input: unknown, services: string[], actor: Actor) {
    this.ui(actor);
    if (!input || typeof input !== "object")
      throw new Fault("BAD_REQUEST", "需要完整托管规则");
    const p = input as ProjectPolicy;
    if (
      typeof p.holdAfterUserStop !== "boolean" ||
      !["allow", "deny"].includes(p.agentForceStop) ||
      !Array.isArray(p.lockedServices) ||
      p.lockedServices.some((s) => typeof s !== "string") ||
      new Set(p.lockedServices).size !== p.lockedServices.length
    )
      throw new Fault("CONFIG_INVALID", "托管规则格式无效", 422);
    if (p.lockedServices.some((s) => !services.includes(s)))
      throw new Fault("CONFIG_INVALID", "锁定列表包含不存在的服务", 422);
    const old = this.get(pid),
      next = {
        holdAfterUserStop: p.holdAfterUserStop,
        agentForceStop: p.agentForceStop,
        lockedServices: [...p.lockedServices],
      };
    this.settings[pid] = next;
    if (
      old.holdAfterUserStop !== next.holdAfterUserStop ||
      old.agentForceStop !== next.agentForceStop
    )
      this.activity.add(pid, actor, {
        kind: "policy",
        change: "settings",
        serviceId: null,
      });
    for (const sid of new Set([
      ...old.lockedServices,
      ...next.lockedServices,
    ])) {
      if (
        old.lockedServices.includes(sid) !== next.lockedServices.includes(sid)
      )
        this.activity.add(pid, actor, {
          kind: "policy",
          change: next.lockedServices.includes(sid) ? "lock" : "unlock",
          serviceId: sid,
        });
    }
    if (!next.holdAfterUserStop)
      for (const sid of Object.keys(this.holds[pid] ?? {}))
        this.release(pid, sid, actor);
    return this.get(pid);
  }
  ui(actor: Actor) {
    if (actor.client !== "ui")
      throw new Fault("FORBIDDEN_CLIENT", "托管规则只能在界面修改", 403);
  }
  release(pid: string, sid: string, actor: Actor) {
    if (!this.hold(pid, sid)) return false;
    delete this.holds[pid]![sid];
    this.activity.add(pid, actor, {
      kind: "policy",
      change: "release",
      serviceId: sid,
    });
    return true;
  }
  denial(
    pid: string,
    sid: string,
    action: ActionKind,
    actor: Actor,
    overrideHold: boolean,
  ) {
    if (actor.client !== "cli") return null;
    const p = this.get(pid);
    const reason = p.lockedServices.includes(sid)
      ? "locked"
      : action === "force-stop" && p.agentForceStop === "deny"
        ? "force-stop"
        : ["start", "restart"].includes(action) &&
            this.hold(pid, sid) &&
            !overrideHold
          ? "hold"
          : null;
    return reason
      ? {
          code: "POLICY_DENIED" as const,
          message:
            reason === "hold"
              ? "你在界面暂停了 AI 启动"
              : reason === "locked"
                ? "服务已锁定，需在界面解锁"
                : "项目不允许 AI 强制停止",
          details: { reason, serviceId: sid },
        }
      : null;
  }
  outcome(
    op: Operation,
    result: OperationTargetResult,
    actor: Actor,
    overrideHold: boolean,
  ) {
    const pid = op.projectId,
      sid = result.serviceId;
    if (
      actor.client === "ui" &&
      ["stop", "force-stop"].includes(op.action) &&
      ["stopped", "stop-timeout"].includes(result.outcome) &&
      this.get(pid).holdAfterUserStop &&
      !this.hold(pid, sid)
    ) {
      (this.holds[pid] ??= {})[sid] = { since: now(), operationId: op.id };
      this.activity.add(pid, actor, {
        kind: "policy",
        change: "hold",
        serviceId: sid,
      });
    }
    if (
      ["start", "restart"].includes(op.action) &&
      ((actor.client === "ui" &&
        ["started", "already-running"].includes(result.outcome)) ||
        (actor.client === "cli" &&
          overrideHold &&
          result.outcome === "started"))
    ) {
      if (this.release(pid, sid, actor) && actor.client === "cli")
        this.overridden.add(op.id);
    }
  }
  prune(pid: string, services: string[], actor: Actor) {
    const policy = this.settings[pid];
    if (policy) {
      for (const sid of policy.lockedServices)
        if (!services.includes(sid))
          this.activity.add(pid, actor, {
            kind: "policy",
            change: "unlock",
            serviceId: sid,
          });
      policy.lockedServices = policy.lockedServices.filter((s) =>
        services.includes(s),
      );
    }
    for (const sid of Object.keys(this.holds[pid] ?? {}))
      if (!services.includes(sid)) this.release(pid, sid, actor);
  }
  remove(pid: string) {
    delete this.settings[pid];
    delete this.holds[pid];
  }
}
