import { comparable } from "./params.ts";
import type {
  Actor,
  ActivityDetail,
  ActivityEntry,
  ActivityPage,
  ConfigDiffEntry,
} from "@devpanel/contract";
import { Fault, id, now } from "./storage.ts";
export const daemonActor: Actor = { client: "daemon", agent: null };
export function requestActor(
  client: string | undefined,
  agent?: string | string[],
): Actor {
  if (client === "ui") return { client: "ui", agent: null };
  if (
    agent !== undefined &&
    (typeof agent !== "string" || !/^[a-z0-9][a-z0-9._-]{0,31}$/.test(agent))
  )
    throw new Fault("BAD_REQUEST", "X-DevPanel-Agent 格式无效");
  return { client: "cli", agent: agent ?? null };
}
/** Compare private snapshots but mask each sensitive leaf before exposing a diff. */
export function configDiff(
  existing: unknown,
  incoming: unknown,
): ConfigDiffEntry[] {
  const changes: ConfigDiffEntry[] = [];
  const secret = (v: unknown) =>
    !!v &&
    typeof v === "object" &&
    "secret" in v &&
    (v as { secret: unknown }).secret === true;
  const publicValue = (v: unknown): unknown => {
    if (secret(v)) return { secret: true };
    if (Array.isArray(v)) return v.map(publicValue);
    if (v && typeof v === "object")
      return Object.fromEntries(
        Object.entries(v).map(([k, x]) => [k, publicValue(x)]),
      );
    return v ?? null;
  };
  const walk = (a: unknown, b: unknown, path: string) => {
    if (JSON.stringify(a) === JSON.stringify(b)) return;
    if (
      !secret(a) &&
      !secret(b) &&
      a &&
      b &&
      typeof a === "object" &&
      typeof b === "object" &&
      Array.isArray(a) === Array.isArray(b)
    ) {
      for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
        walk(
          (a as Record<string, unknown>)[k],
          (b as Record<string, unknown>)[k],
          Array.isArray(a) ? `${path}[${k}]` : path ? `${path}.${k}` : k,
        );
      }
    } else
      changes.push({
        path: path || "config",
        existing: publicValue(a),
        incoming: publicValue(b),
      });
  };
  walk(comparable(existing), comparable(incoming), "");
  return changes;
}
export class Activities {
  entries: ActivityEntry[];
  readonly kept: number;
  constructor(entries: ActivityEntry[] = [], kept = 500) {
    this.entries = entries;
    this.kept = kept;
  }
  add(projectId: string, actor: Actor, detail: ActivityDetail) {
    const entry: ActivityEntry = {
      id: id("a"),
      projectId,
      at: now(),
      actor: structuredClone(actor),
      detail,
    };
    this.entries.push(entry);
    const project = this.entries.filter((e) => e.projectId === projectId);
    const remove = new Set(
      project
        .slice(0, Math.max(0, project.length - this.kept))
        .map((e) => e.id),
    );
    this.entries = this.entries.filter((e) => !remove.has(e.id));
    return entry;
  }
  config(
    projectId: string,
    actor: Actor,
    change: "register" | "update" | "param",
    fromRevision: number,
    toRevision: number,
    before: unknown,
    after: unknown,
  ) {
    const changes = configDiff(before, after);
    this.add(projectId, actor, {
      kind: "config",
      change,
      fromRevision,
      toRevision,
      changes: changes.slice(0, 100),
      changesTruncated: changes.length > 100,
    });
  }
  page(projectId: string, before: string | null, limit = 50): ActivityPage {
    if (!Number.isInteger(limit) || limit < 1 || limit > 200)
      throw new Fault("BAD_REQUEST", "limit 必须在 1–200");
    const rows = this.entries
      .filter((e) => e.projectId === projectId)
      .reverse();
    const index =
      before === null ? 0 : rows.findIndex((e) => e.id === before) + 1;
    if (before !== null && index === 0)
      throw new Fault("BAD_REQUEST", "before 动态不存在");
    return {
      entries: rows.slice(index, index + limit),
      hasMore: rows.length > index + limit,
    };
  }
}
