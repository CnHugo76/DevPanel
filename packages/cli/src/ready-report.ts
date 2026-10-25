import type {
  CliStartReport,
  Operation,
  RunSummary,
  LogDigest,
  ServiceStats,
} from "@devpanel/contract";
import { digestText } from "./digest-text.ts";
import { api, operationCode, ClientError, exitCode } from "./client.ts";

export function reportCode(report: CliStartReport, expired = false): number {
  const operation = operationCode(report.operation);
  if (operation) return operation;
  if (expired) return 8;
  if (report.services.some((s) => s.ready?.state === "ended-before-ready"))
    return 1;
  if (report.services.some((s) => s.ready?.state === "timed-out")) return 11;
  return 0;
}

export async function startReport(
  operation: Operation,
  timeout: number,
): Promise<{ report: CliStartReport; code: number }> {
  const deadline = Date.now() + timeout * 1000;
  let expired = false,
    requestError = 0;
  const services = await Promise.all(
    operation.results.map(async (result) => {
      const service: CliStartReport["services"][number] = {
        serviceId: result.serviceId,
        runId: result.runId ?? null,
        outcome: result.outcome,
        ready: null,
        listening: null,
        digest: null,
      };
      try {
        let run = result.runId
          ? await api<RunSummary>(`/runs/${result.runId}`)
          : null;
        if (["started", "already-running"].includes(result.outcome)) {
          while (run?.ready?.state === "waiting") {
            const remaining = deadline - Date.now();
            if (remaining <= 0) {
              expired = true;
              break;
            }
            service.ready = run.ready;
            run = await api<RunSummary>(
              `/runs/${run.id}/ready/wait?timeoutMs=${Math.min(60000, Math.max(0, Math.floor(remaining)))}`,
            );
          }
        }
        service.ready = run?.ready ?? null;
        if (
          run &&
          (result.outcome === "failed" ||
            ["ended-before-ready", "timed-out"].includes(
              run.ready?.state ?? "",
            ))
        ) {
          service.digest = await api<LogDigest>(`/runs/${run.id}/digest`);
        }
      } catch (error) {
        if (!(error instanceof ClientError)) throw error;
        requestError ||= exitCode(error.body.error.code);
      }
      return service;
    }),
  );
  try {
    const stats = await api<{ services: Record<string, ServiceStats> }>(
      `/projects/${operation.projectId}/stats`,
    );
    for (const service of services) {
      if (stats.services?.[service.serviceId]?.runId === service.runId)
        service.listening = stats.services[service.serviceId]!.listening;
    }
  } catch (error) {
    if (!(error instanceof ClientError)) throw error;
    requestError ||= exitCode(error.body.error.code);
  }
  const report = { operation, services };
  const code = reportCode(report, expired);
  return { report, code: operationCode(operation) || requestError || code };
}

export function reportText(report: CliStartReport): string {
  const outcomes: Record<string, string> = {
    started: "启动完成",
    "already-running": "已在运行",
    failed: "失败",
    pending: "等待操作",
    cancelled: "已取消",
  };
  const states: Record<string, string> = {
    ready: "已就绪",
    waiting: "等待中",
    "not-configured": "未配置",
    "timed-out": "超时未就绪",
    "ended-before-ready": "就绪前结束",
    unknown: "就绪未知",
  };
  return report.services
    .map(
      (s) =>
        `${s.serviceId}: ${outcomes[s.outcome] ?? s.outcome} · ${s.ready ? (states[s.ready.state] ?? s.ready.state) : "未知"}${s.ready?.afterMs == null ? "" : ` · ${(s.ready.afterMs / 1000).toFixed(1)} 秒`}${s.listening?.length ? ` · 端口 ${s.listening.map((p) => p.port).join(", ")}` : ""}${s.digest ? `\n${digestText(s.digest)}` : ""}`,
    )
    .join("\n");
}
