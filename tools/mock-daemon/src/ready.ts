import { stripVTControlCharacters } from "node:util";
import type {
  ListeningPort,
  LogLine,
  ProjectConfig,
  ReadyConfig,
  ReadyInfo,
  ValidationIssue,
} from "@devpanel/contract";

// Virtual readiness only: no OS process or socket probes, no daemon implementation.
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
  const issue = (
    field: string,
    message: string,
    code: ValidationIssue["code"] = "CONFIG_INVALID",
  ) => issues.push({ path: path + field, message, code, severity: "error" });
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    issue("", "就绪条件必须为对象");
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
    issue(".timeoutSec", "等待上限必须在 1–900 秒");
  const check = ready.check;
  if (
    !check ||
    typeof check !== "object" ||
    Array.isArray(check) ||
    !["log", "port"].includes(check.kind)
  )
    issue(".check", "请选择日志或端口条件");
  else if (check.kind === "log") {
    if (
      !Array.isArray(check.contains) ||
      check.contains.length < 1 ||
      check.contains.length > 5 ||
      check.contains.some(
        (text) =>
          typeof text !== "string" ||
          [...text].length < 1 ||
          [...text].length > 200,
      )
    )
      issue(".check.contains", "日志文字须为 1–5 项，每项 1–200 字符");
  } else if (check.port !== undefined) {
    let port: unknown = check.port;
    if (typeof port === "string") {
      const key = /^\$\{([a-zA-Z][a-zA-Z0-9_]{0,31})\}$/.exec(port)?.[1];
      const param = config.params?.find((param) => param.key === key);
      if (key && !param) {
        issue(".check.port", "引用了未定义选项", "PARAM_UNKNOWN");
        return issues;
      }
      if (!key || param?.type !== "number" || param.secret) {
        issue(".check.port", "就绪端口须引用非敏感数字选项", "PARAM_INVALID");
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
      issue(".check.port", "端口必须为 1–65535 的整数", "PARAM_INVALID");
  }
  return issues;
}
export function readySnapshot(
  config: ProjectConfig,
  ready?: ReadyConfig,
): ReadyConfig | undefined {
  if (!ready) return undefined;
  const result = structuredClone(ready);
  if (result.check.kind === "port" && typeof result.check.port === "string") {
    const key = result.check.port.slice(2, -1);
    result.check.port = config.params?.find((param) => param.key === key)
      ?.value as number;
  }
  return result;
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
  if (
    line.seq <= tracking.seq ||
    line.stream === "sys" ||
    tracking.config.check.kind !== "log"
  )
    return null;
  tracking.seq = line.seq;
  const text = stripVTControlCharacters(
    (tracking.tails[line.stream] ?? "") + line.text,
  );
  tracking.tails[line.stream] = line.partial ? text.slice(-1024) : "";
  return tracking.config.check.contains.some((word) => text.includes(word))
    ? { kind: "log", seq: line.seq }
    : null;
}
export function portEvidence(
  config: ReadyConfig,
  ports: ListeningPort[] | null,
): ReadyInfo["evidence"] {
  if (config.check.kind !== "port") return null;
  const expected = config.check.port;
  const port = ports?.find(
    (port) => expected === undefined || port.port === expected,
  );
  return port ? { kind: "port", port: port.port, address: port.address } : null;
}
