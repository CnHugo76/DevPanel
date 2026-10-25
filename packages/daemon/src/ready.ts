import { stripVTControlCharacters } from "node:util";
import type {
  ReadyConfig,
  ReadyInfo,
  LogLine,
  ListeningPort,
  ProjectConfig,
  ValidationIssue,
} from "@devpanel/contract";
export const noReady = (): ReadyInfo => ({
  state: "not-configured",
  at: null,
  afterMs: null,
  evidence: null,
});
export function readyIssues(
  value: unknown,
  config: Pick<ProjectConfig, "params">,
  path: string,
): ValidationIssue[] {
  const issues: ValidationIssue[] = [];
  const add = (
    field: string,
    message: string,
    code: ValidationIssue["code"] = "CONFIG_INVALID",
  ) =>
    issues.push({ path: `${path}${field}`, message, code, severity: "error" });
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    add("", "就绪条件必须为对象");
    return issues;
  }
  const ready = value as ReadyConfig;
  if (
    ready.timeoutSec !== undefined &&
    (typeof ready.timeoutSec !== "number" ||
      !Number.isFinite(ready.timeoutSec) ||
      ready.timeoutSec < 1 ||
      ready.timeoutSec > 900)
  )
    add(".timeoutSec", "等待上限必须在 1–900 秒");
  const c = ready.check;
  if (
    !c ||
    typeof c !== "object" ||
    Array.isArray(c) ||
    !["log", "port"].includes(c.kind)
  ) {
    add(".check", "请选择日志或端口条件");
    return issues;
  }
  if (c.kind === "log") {
    if (
      !Array.isArray(c.contains) ||
      c.contains.length < 1 ||
      c.contains.length > 5 ||
      c.contains.some(
        (s) =>
          typeof s !== "string" || [...s].length < 1 || [...s].length > 200,
      )
    )
      add(".check.contains", "日志文字须为 1–5 项，每项 1–200 字符");
  } else if (c.port !== undefined) {
    let port: unknown = c.port;
    if (typeof port === "string") {
      const key = port.match(/^\$\{([a-zA-Z][a-zA-Z0-9_]{0,31})\}$/)?.[1];
      if (!key) {
        add(".check.port", "端口只支持数字或完整选项引用", "PARAM_INVALID");
        return issues;
      }
      const param = (Array.isArray(config.params) ? config.params : []).find(
        (p) => p?.key === key,
      );
      if (!param) {
        add(".check.port", "引用了未定义选项", "PARAM_UNKNOWN");
        return issues;
      }
      if (param.type !== "number" || param.secret) {
        add(".check.port", "就绪端口须引用非敏感数字选项", "PARAM_INVALID");
        return issues;
      }
      port = param.value;
    }
    if (
      typeof port !== "number" ||
      !Number.isInteger(port) ||
      port < 1 ||
      port > 65535
    )
      add(".check.port", "端口必须为 1–65535 的整数", "PARAM_INVALID");
  }
  return issues;
}
export function readySnapshot(
  config: ProjectConfig,
  ready?: ReadyConfig,
): ReadyConfig | undefined {
  if (!ready) return undefined;
  const snapshot = structuredClone(ready);
  if (
    snapshot.check.kind === "port" &&
    typeof snapshot.check.port === "string"
  ) {
    const key = snapshot.check.port.slice(2, -1);
    snapshot.check.port = config.params!.find((p) => p.key === key)!
      .value as number;
  }
  return snapshot;
}
export interface ReadyTracking {
  config: ReadyConfig;
  seq: number;
  tails: Partial<Record<"out" | "err", string>>;
}
export function logEvidence(
  tracking: ReadyTracking,
  line: LogLine,
): ReadyInfo["evidence"] {
  if (line.seq <= tracking.seq) return null;
  tracking.seq = line.seq;
  if (line.stream === "sys" || tracking.config.check.kind !== "log")
    return null;
  const text = (tracking.tails[line.stream] ?? "") + line.text;
  const plain = stripVTControlCharacters(text);
  // Only the longest possible cross-chunk match is retained, independent of producer line length.
  tracking.tails[line.stream] = line.partial ? text.slice(-1024) : "";
  return tracking.config.check.contains.some((needle) => plain.includes(needle))
    ? { kind: "log", seq: line.seq }
    : null;
}
export function portEvidence(
  config: ReadyConfig,
  ports: ListeningPort[] | null,
): ReadyInfo["evidence"] {
  if (config.check.kind !== "port") return null;
  const expected = config.check.port,
    port = ports?.find((p) => expected === undefined || p.port === expected);
  return port ? { kind: "port", port: port.port, address: port.address } : null;
}

export const readyTimeoutMs = (config: ReadyConfig): number =>
  (config.timeoutSec ?? 120) * 1000;
