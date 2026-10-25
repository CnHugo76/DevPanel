import type {
  Actor,
  ActionKind,
  Operation,
  OperationTargetResult,
  ProjectPolicy,
  ServiceHold,
} from "@devpanel/contract";
import type { Activities } from "./activity.ts";
import { HttpError, badRequest } from "./errors.ts";
import { iso } from "./util.ts";

/** Only virtual, in-memory permissions and holds needed for UI scenarios. */
export class Policies {
  private settings = new Map<string, ProjectPolicy>();
  holds: Record<string, Record<string, ServiceHold>> = {};
  readonly overridden = new Set<string>();
  private readonly activity: Activities;
  constructor(activity: Activities) {
    this.activity = activity;
  }
  get(pid: string): ProjectPolicy {
    return structuredClone(
      this.settings.get(pid) ?? {
        holdAfterUserStop: true,
        agentForceStop: "deny",
        lockedServices: [],
      },
    );
  }
  hold(pid: string, sid: string): ServiceHold | null {
    return this.holds[pid]?.[sid] ?? null;
  }
  ui(actor: Actor) {
    if (actor.client !== "ui")
      throw new HttpError(403, "FORBIDDEN_CLIENT", "托管规则只能在界面修改");
  }
  private record(
    pid: string,
    actor: Actor,
    change: "settings" | "lock" | "unlock" | "hold" | "release",
    serviceId: string | null = null,
  ) {
    this.activity.add(pid, actor, { kind: "policy", change, serviceId });
  }
  set(
    pid: string,
    input: unknown,
    services: string[],
    actor: Actor,
  ): ProjectPolicy {
    this.ui(actor);
    if (!input || typeof input !== "object")
      throw badRequest("需要完整托管规则");
    const next = input as ProjectPolicy;
    if (
      typeof next.holdAfterUserStop !== "boolean" ||
      !["allow", "deny"].includes(next.agentForceStop) ||
      !Array.isArray(next.lockedServices) ||
      next.lockedServices.some((sid) => !services.includes(sid)) ||
      new Set(next.lockedServices).size !== next.lockedServices.length
    )
      throw new HttpError(422, "CONFIG_INVALID", "托管规则格式无效");
    const old = this.get(pid);
    this.settings.set(
      pid,
      structuredClone({
        holdAfterUserStop: next.holdAfterUserStop,
        agentForceStop: next.agentForceStop,
        lockedServices: next.lockedServices,
      }),
    );
    if (
      old.holdAfterUserStop !== next.holdAfterUserStop ||
      old.agentForceStop !== next.agentForceStop
    )
      this.record(pid, actor, "settings");
    for (const sid of old.lockedServices.filter(
      (sid) => !next.lockedServices.includes(sid),
    ))
      this.record(pid, actor, "unlock", sid);
    for (const sid of next.lockedServices.filter(
      (sid) => !old.lockedServices.includes(sid),
    ))
      this.record(pid, actor, "lock", sid);
    if (!next.holdAfterUserStop)
      for (const sid of Object.keys(this.holds[pid] ?? {}))
        this.release(pid, sid, actor);
    return this.get(pid);
  }
  release(pid: string, sid: string, actor: Actor): boolean {
    if (!this.hold(pid, sid)) return false;
    delete this.holds[pid]![sid];
    this.record(pid, actor, "release", sid);
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
    const policy = this.get(pid);
    let reason: "locked" | "force-stop" | "hold" | undefined;
    if (policy.lockedServices.includes(sid)) reason = "locked";
    else if (action === "force-stop" && policy.agentForceStop === "deny")
      reason = "force-stop";
    else if (
      (action === "start" || action === "restart") &&
      this.hold(pid, sid) &&
      !overrideHold
    )
      reason = "hold";
    return reason
      ? {
          code: "POLICY_DENIED" as const,
          message: "模拟托管规则拒绝：" + reason,
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
    if (op.action === "stop" || op.action === "force-stop") {
      if (
        actor.client === "ui" &&
        this.get(pid).holdAfterUserStop &&
        ["stopped", "stop-timeout"].includes(result.outcome) &&
        !this.hold(pid, sid)
      ) {
        (this.holds[pid] ??= {})[sid] = { since: iso(), operationId: op.id };
        this.record(pid, actor, "hold", sid);
      }
    } else if (
      (actor.client === "ui" &&
        ["started", "already-running"].includes(result.outcome)) ||
      (actor.client === "cli" && overrideHold && result.outcome === "started")
    ) {
      if (this.release(pid, sid, actor) && actor.client === "cli")
        this.overridden.add(op.id);
    }
  }
  prune(pid: string, services: string[], actor: Actor) {
    const policy = this.settings.get(pid);
    if (policy) {
      for (const sid of policy.lockedServices.filter(
        (sid) => !services.includes(sid),
      ))
        this.record(pid, actor, "unlock", sid);
      policy.lockedServices = policy.lockedServices.filter((sid) =>
        services.includes(sid),
      );
    }
    for (const sid of Object.keys(this.holds[pid] ?? {}).filter(
      (sid) => !services.includes(sid),
    ))
      this.release(pid, sid, actor);
  }
  remove(pid: string) {
    this.settings.delete(pid);
    delete this.holds[pid];
  }
}
