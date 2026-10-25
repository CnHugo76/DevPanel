import { request, type IncomingMessage } from "node:http";
import { join } from "node:path";
import { homedir } from "node:os";
import type { ErrorBody, Operation } from "@devpanel/contract";
export const homePath = () =>
  process.env.DEVPANEL_HOME ||
  join(homedir(), "Library/Application Support/DevPanel");
export class ClientError extends Error {
  body: ErrorBody;
  constructor(body: ErrorBody) {
    super(body.error.message);
    this.body = body;
  }
}
export function exitCode(error: ErrorBody["error"]["code"]) {
  if (
    error === "BAD_REQUEST" ||
    error === "CONFIG_INVALID" ||
    error === "PARAM_INVALID" || error === "MAVEN_INVALID"
  )
    return 2;
  if (error === "DAEMON_UNREACHABLE") return 3;
  if (error.endsWith("_NOT_FOUND") && error !== "COMMAND_NOT_FOUND") return 4;
  if (
    ["CONFIG_CONFLICT", "REVISION_MISMATCH", "PROJECT_RUNNING", "TASK_RUNNING"].includes(error)
  )
    return 5;
  if (error === "STOP_TIMEOUT") return 7;
  if (error === "OPERATION_CANCELLED") return 9;
  return 1;
}
export function operationCode(op: Operation) {
  if (op.state === "queued" || op.state === "running") return 8;
  const failures = op.results.filter(r => ["failed", "stop-timeout", "cancelled"].includes(r.outcome));
  if (failures.length && failures.every(r => r.outcome === "failed" && r.error?.code === "POLICY_DENIED")) return 12;
  if (op.state === "cancelled") return 9;
  if (op.state === "partial") return 6;
  if (
    op.results.some(
      (r) => r.outcome === "stop-timeout" || r.error?.code === "STOP_TIMEOUT",
    )
  )
    return 7;
  return op.state === "succeeded" ? 0 : op.state === "failed" ? 1 : 8;
}
export const unreachable = () =>
  new ClientError({
    error: {
      code: "DAEMON_UNREACHABLE",
      message: "无法连接管理服务，请运行 devpanel daemon start",
    },
  });
let agentName: string | undefined;
export function setAgent(value: string | undefined) {
  if (value !== undefined && !/^[a-z0-9][a-z0-9._-]{0,31}$/.test(value)) throw new ClientError({ error: { code: "BAD_REQUEST", message: "agent 名称格式无效" } });
  agentName = value;
}
export function raw(
  path: string,
  method = "GET",
  data?: unknown,
): Promise<IncomingMessage> {
  return new Promise((resolve, reject) => {
    const req = request(
      {
        socketPath: join(homePath(), "run/devpanel.sock"),
        path: "/api/v1" + path,
        method,
        headers: {
          "X-DevPanel-Client": "cli",
          "Content-Type": "application/json",
          ...(agentName === undefined ? {} : { "X-DevPanel-Agent": agentName }),
        },
      },
      (res) => resolve(res),
    );
    req.on("error", () => reject(unreachable()));
    req.setTimeout(path === "/daemon/shutdown" ? 310000 : 65000, () => {
      req.destroy();
      reject(unreachable());
    });
    req.end(data === undefined ? undefined : JSON.stringify(data));
  });
}
export async function api<T = unknown>(
  path: string,
  method = "GET",
  data?: unknown,
): Promise<T> {
  const res = await raw(path, method, data);
  const chunks: Buffer[] = [];
  for await (const chunk of res) chunks.push(chunk);
  let result: unknown;
  try {
    result = chunks.length
      ? JSON.parse(Buffer.concat(chunks).toString("utf8"))
      : null;
  } catch {
    throw new ClientError({
      error: { code: "INTERNAL", message: "管理服务返回了无效 JSON" },
    });
  }
  if ((res.statusCode ?? 500) >= 400)
    throw new ClientError(result as ErrorBody);
  return result as T;
}
