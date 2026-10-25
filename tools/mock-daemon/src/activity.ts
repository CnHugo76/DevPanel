import type {
  Actor,
  ActivityDetail,
  ActivityEntry,
  ActivityPage,
  ConfigDiffEntry,
} from "@devpanel/contract";
import { badRequest } from "./errors.ts";
import { iso, stableStringify, ulid } from "./util.ts";
import { stripResponseOnly } from "./params.ts";

export const daemonActor: Actor = { client: "daemon", agent: null };
export function validateAgentHeader(
  client: string | undefined,
  agent?: string | string[],
): void {
  if (
    client !== "ui" &&
    agent !== undefined &&
    (typeof agent !== "string" || !/^[a-z0-9][a-z0-9._-]{0,31}$/.test(agent))
  )
    throw badRequest("X-DevPanel-Agent 格式无效");
}
export function requestActor(
  client: string | undefined,
  agent?: string | string[],
): Actor {
  validateAgentHeader(client, agent);
  return {
    client: client === "ui" ? "ui" : "cli",
    agent: client === "ui" ? null : ((agent as string | undefined) ?? null),
  };
}

/** A virtual leaf diff is sufficient for mock config banners and seeded activity. */
export function configDiff(before: unknown, after: unknown): ConfigDiffEntry[] {
  function leaves(
    value: unknown,
    path = "",
    result = new Map<string, { privateValue: unknown; publicValue: unknown }>(),
  ) {
    if (value && typeof value === "object") {
      const object =
        "key" in value && "type" in value
          ? stripResponseOnly(value as import("@devpanel/contract").ParamConfig)
          : value;
      if ("secret" in object && object.secret === true)
        result.set(path, {
          privateValue: object,
          publicValue: { secret: true },
        });
      else
        for (const [key, child] of Object.entries(object))
          leaves(
            child,
            Array.isArray(object)
              ? `${path}[${key}]`
              : path
                ? `${path}.${key}`
                : key,
            result,
          );
    } else if (value !== undefined)
      result.set(path || "config", { privateValue: value, publicValue: value });
    return result;
  }
  const old = leaves(before),
    next = leaves(after);
  return [...new Set([...old.keys(), ...next.keys()])]
    .filter(
      (path) =>
        stableStringify(old.get(path)?.privateValue) !==
        stableStringify(next.get(path)?.privateValue),
    )
    .map((path) => ({
      path,
      existing: old.get(path)?.publicValue ?? null,
      incoming: next.get(path)?.publicValue ?? null,
    }));
}

/** In-memory mock history; no persistence or recovery behavior. */
export class Activities {
  entries: ActivityEntry[] = [];
  private readonly kept: number;
  constructor(kept = 500) {
    this.kept = kept;
  }
  add(projectId: string, actor: Actor, detail: ActivityDetail): ActivityEntry {
    const entry = {
      id: "a_" + ulid(),
      projectId,
      at: iso(),
      ...structuredClone({ actor, detail }),
    };
    this.entries.push(entry);
    let left = this.kept;
    this.entries = this.entries
      .toReversed()
      .filter((row) => row.projectId !== projectId || left-- > 0)
      .toReversed();
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
      throw badRequest("limit 必须在 1–200");
    const rows = this.entries
      .filter((row) => row.projectId === projectId)
      .toReversed();
    const offset =
      before === null ? 0 : rows.findIndex((row) => row.id === before) + 1;
    if (before !== null && offset === 0) throw badRequest("before 动态不存在");
    return {
      entries: rows.slice(offset, offset + limit),
      hasMore: rows.length > offset + limit,
    };
  }
}
