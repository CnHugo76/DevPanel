#!/usr/bin/env node
import { readFileSync, mkdirSync, openSync, closeSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { parseArgs } from "node:util";
import type {
  Operation,
  StartTaskRunResponse,
  ProjectView,
  Project,
  RunSummary,
  TaskRunSummary,
  LogPage,
  LogDigest,
  LogStreamEvent,
  DaemonInfo,
  ErrorBody,
} from "@devpanel/contract";
import {
  api,
  raw,
  ClientError,
  exitCode,
  operationCode,
  homePath,
  setAgent,
} from "./client.ts";
import { socketPathError } from "@devpanel/daemon/socket-path";
import { installLaunchAgent, uninstallLaunchAgent } from "./launch-agent.ts";
import { startReport, reportText } from "./ready-report.ts";
import { digestText } from "./digest-text.ts";
import { waitTask } from "./task-commands.ts";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const usage = () =>
  new ClientError({
    error: {
      code: "BAD_REQUEST",
      message:
        "用法：devpanel daemon start|stop|status|install|uninstall；project register|update|show|list|remove|validate|rules；status|start|stop|restart|force-stop|operation|logs|stats|activity|policy <项目或操作 ID>；param list|set|remove；action list|run；task cancel；maven modules|run；open",
    },
  });
let jsonOutput = process.argv.includes("--json");
function numeric(v: string | undefined, defaultValue: number) {
  if (v === undefined) return defaultValue;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) throw usage();
  return n;
}
function load(path: string | undefined): unknown {
  if (!path) throw usage();
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    throw new ClientError({
      error: { code: "CONFIG_INVALID", message: "无法读取 JSON 配置文件" },
    });
  }
}
function print(value: unknown) {
  process.stdout.write(
    typeof value === "string" && !jsonOutput
      ? value + "\n"
      : JSON.stringify(value, null, jsonOutput ? undefined : 2) + "\n",
  );
}
function need(value: string | undefined) {
  if (!value) throw usage();
  return encodeURIComponent(value);
}
async function wait(op: Operation, timeout: number) {
  const until = Date.now() + timeout * 1000;
  while (["queued", "running"].includes(op.state) && Date.now() < until)
    op = await api<Operation>(
      `/operations/${op.id}/wait?timeoutMs=${Math.min(60000, Math.max(0, Math.floor(until - Date.now())))}`,
    );
  return op;
}
async function startDaemon() {
  const home = homePath();
  const pathError = socketPathError(home);
  if (pathError) throw new ClientError({ error: pathError });
  try {
    return await api<DaemonInfo>("/daemon");
  } catch (e) {
    if (
      !(e instanceof ClientError) ||
      e.body.error.code !== "DAEMON_UNREACHABLE"
    )
      throw e;
  }
  mkdirSync(home, { recursive: true, mode: 0o700 });
  const fd = openSync(join(home, "daemon-start.log"), "w", 0o600);
  const child = spawn(
    process.execPath,
    [fileURLToPath(import.meta.resolve("@devpanel/daemon"))],
    { detached: true, stdio: ["ignore", fd, fd], env: process.env },
  );
  closeSync(fd);
  let failed = false;
  child.once("error", () => {
    failed = true;
  });
  child.unref();
  for (let i = 0; i < 100; i++) {
    try {
      return await api<DaemonInfo>("/daemon");
    } catch {}
    if (failed || child.exitCode !== null) break;
    await sleep(50);
  }
  throw new ClientError({
    error: {
      code: "INTERNAL",
      message: "daemon 启动失败，请检查数据目录中的 daemon-start.log",
    },
  });
}
async function main() {
  const { values: v, positionals: p } = parseArgs({
    allowPositionals: true,
    strict: true,
    options: {
      json: { type: "boolean" },
      agent: { type: "string" },
      limit: { type: "string" },
      digest: { type: "boolean" },
      "after-seq": { type: "string" },
      "max-bytes": { type: "string" },
      force: { type: "boolean" },
      inline: { type: "boolean" },
      "override-user-values": { type: "boolean" },
      "override-hold": { type: "boolean" },
      config: { type: "string" },
      "if-revision": { type: "string" },
      module: { type: "string" },
      "maven-project": { type: "string" },
      profiles: { type: "string", short: "P", multiple: true },
      "skip-tests": { type: "boolean" },
      offline: { type: "boolean" },
      "also-make": { type: "boolean" },
      service: { type: "string", multiple: true },
      "wait-ready": { type: "boolean" },
      "ready-timeout": { type: "string" },
      "no-wait": { type: "boolean" },
      timeout: { type: "string" },
      run: { type: "string" },
      tail: { type: "string" },
      follow: { type: "boolean" },
      "stop-services": { type: "boolean" },
      help: { type: "boolean" },
    },
  });
  jsonOutput = v.json ?? false;
  setAgent(v.agent ?? (process.env.DEVPANEL_AGENT || undefined));
  const [cmd, arg, third] = p;
  if (v.help) {
    print(
      "DevPanel：本地项目运行面板\n\n" +
        usage().message +
        "\n\n控制命令支持 --service <id>（可重复）、--no-wait、--timeout <秒>、--json。\n启动/重启支持 --wait-ready、--ready-timeout <秒>。日志支持 --digest、--after-seq <行号>、--max-bytes <字节>、--json。\nMaven 支持 --maven-project <工程ID> 选择已登记工程，--module <模块ID> 选择工程内模块。\n所有服务控制均经由 daemon；注册和更新不会执行项目命令。",
    );
    return;
  }
  if (!cmd) throw usage();
  if (v["wait-ready"] && (v["no-wait"] || !["start", "restart"].includes(cmd))) throw usage();
  if (v["ready-timeout"] !== undefined) { if (!v["wait-ready"]) throw usage(); numeric(v["ready-timeout"], 900); }
  if (cmd === "daemon") {
    if (p.length !== 2) throw usage();
    if (arg === "install") {
      print(await installLaunchAgent());
      return;
    }
    if (arg === "uninstall") {
      const result = await uninstallLaunchAgent(v["stop-services"] ?? false);
      print(result);
      if ("state" in result)
        process.exitCode = operationCode(result as Operation);
      return;
    }
    if (arg === "start") {
      print(await startDaemon());
      return;
    }
    if (arg === "status") {
      print(await api("/daemon"));
      return;
    }
    if (arg === "stop") {
      const result = await api<Operation | Record<string, never>>(
        "/daemon/shutdown",
        "POST",
        { stopServices: v["stop-services"] ?? false },
      );
      print(result);
      if ("state" in result)
        process.exitCode = operationCode(result as Operation);
      return;
    }
    throw usage();
  }
  if (cmd === "open") {
    if (p.length !== 1) throw usage();
    const result = await api<{ url: string }>("/auth/ui-code", "POST", {});
    const child = spawn(
      process.platform === "darwin" ? "/usr/bin/open" : "xdg-open",
      [result.url],
      { stdio: "ignore" },
    );
    await new Promise<void>((resolve, reject) => {
      child.once("error", () =>
        reject(
          new ClientError({
            error: { code: "INTERNAL", message: "无法打开默认浏览器" },
          }),
        ),
      );
      child.once("exit", (code) =>
        code === 0
          ? resolve()
          : reject(
              new ClientError({
                error: { code: "INTERNAL", message: "无法打开默认浏览器" },
              }),
            ),
      );
    });
    print({ opened: true });
    return;
  }
  if (cmd === "project") {
    if (arg === "register" && p.length === 2) {
      print(await api("/projects", "POST", load(v.config)));
      return;
    }
    if (arg === "validate" && p.length === 2) {
      const result = await api<{ ok: boolean }>(
        "/config/validate",
        "POST",
        load(v.config),
      );
      print(result);
      if (!result.ok) process.exitCode = 2;
      return;
    }
    if (arg === "list" && p.length === 2) {
      print(await api("/projects"));
      return;
    }
    if (p.length !== 3) throw usage();
    const id = need(third);
    if (arg === "update") {
      const revision = numeric(v["if-revision"], NaN);
      if (!Number.isInteger(revision) || revision < 1) throw usage();
      print(
        await api(`/projects/${id}`, "PUT", {
          ifRevision: revision,
          config: load(v.config),
          ...(v["override-user-values"] ? { overrideUserValues: true } : {}),
        }),
      );
      return;
    }
    if (arg === "show") {
      print(await api(`/projects/${id}`));
      return;
    }
    if (arg === "remove") {
      await api(`/projects/${id}`, "DELETE");
      print(null);
      return;
    }
    if (arg === "rules") {
      const project = await api<Project>(`/projects/${id}`);
      print(
        `本项目的长期运行服务统一由 DevPanel 管理。\n\n项目 ID：${project.id}\n\n启动前先运行 devpanel status ${project.id} --json。\n启动、停止、重启、查看日志和资源使用 DevPanel CLI，不另用 nohup、&、tmux 或 Agent 临时后台任务启动同一服务。\nDevPanel 不可用时报告问题，不绕过它启动项目。\n不要接管或结束不属于本项目受管运行的进程。\n用户主动停止后，结束当前自动启动/重启流程，不自行循环重试。\n用户明确重新要求启动时，读取最新状态后通过 DevPanel 发起新请求。\n修改配置应更新已注册项目，不注册重复项目。\n注册和更新配置不等于执行授权。\n接入新项目时登记就绪条件（日志文字或监听端口）；注册不启动服务。\n启动和重启使用 --wait-ready --json，停止仍用 stop。退出码 11 表示就绪超时，服务可能仍在运行，不自动停止或重启；退出码 12 表示失败目标全部被托管规则拒绝，报告原因，不绕过规则。\n读日志优先使用 --digest，记下 lastSeq；修改并重试后用 --after-seq <lastSeq> 读取同一运行的增量，换运行时重新开始。\n请在 agent 配置里设置 DEVPANEL_AGENT，名称只用于记录。常改的配置请提炼为选项（params）并写明说明；不要覆盖用户改过的值。\n使用 devpanel param list/set/remove 管理选项；修改只在下次启动生效。`,
      );
      return;
    }
    throw usage();
  }
  if (cmd === "param") {
    if (
      !third ||
      !["list", "set", "remove"].includes(arg || "") ||
      p.length !== (arg === "list" ? 3 : arg === "set" ? 5 : 4)
    )
      throw usage();
    const project = await api<Project>(`/projects/${need(third)}`);
    if (arg === "list") {
      print(project.config.params || []);
      return;
    }
    const key = p[3]!;
    const param = project.config.params?.find((p) => p.key === key);
    if (!param)
      throw new ClientError({
        error: { code: "PARAM_UNKNOWN", message: "选项不存在" },
      });
    const revision = numeric(v["if-revision"], project.revision);
    if (!Number.isInteger(revision) || revision < 1) throw usage();
    const path = `/projects/${need(third)}/params/${encodeURIComponent(key)}`;
    if (arg === "remove") {
      print(
        await api(
          `${path}?ifRevision=${revision}&inline=${v.inline === true}`,
          "DELETE",
        ),
      );
      return;
    }
    const text = p[4]!;
    let value: string | number | boolean = text;
    if (param.type === "number") value = text.trim() ? Number(text) : NaN;
    if (param.type === "boolean")
      value = text === "true" ? true : text === "false" ? false : text;
    if (
      (param.type === "number" && !Number.isFinite(value)) ||
      (param.type === "boolean" && typeof value !== "boolean") ||
      (param.type === "enum" &&
        !param.choices?.some((c) => c.value === value)) ||
      (typeof value === "number" &&
        ((param.min !== undefined && value < param.min) ||
          (param.max !== undefined && value > param.max)))
    )
      throw new ClientError({
        error: {
          code: "PARAM_INVALID",
          message: "选项值不符合类型、可选值或范围",
        },
      });
    print(await api(path, "PATCH", { ifRevision: revision, value }));
    return;
  }
  if (cmd === "maven") {
    const pid = need(third);
    if (arg === "modules" && p.length === 3) { print(await api(`/projects/${pid}/maven${v["maven-project"] ? "?mavenProjectId=" + encodeURIComponent(String(v["maven-project"])) : ""}`)); return; }
    if (arg !== "run" || p.length < 4) throw usage();
    const start = await api<StartTaskRunResponse>(`/projects/${pid}/maven/runs`, "POST", {
      ...(v["maven-project"] ? { mavenProjectId: String(v["maven-project"]) } : {}),
      moduleId: v.module ?? ".", goals: p.slice(3), profiles: v.profiles?.flatMap(p => p.split(",")),
      skipTests: v["skip-tests"], offline: v.offline, alsoMake: v["also-make"],
    });
    const result = await waitTask(start, { noWait: v["no-wait"], follow: v.follow, timeout: numeric(v.timeout, 60), json: jsonOutput });
    print(result.value); process.exitCode = result.code; return;
  }
  if (cmd === "action") {
    const pid = need(third);
    if (arg === "list" && p.length === 3) { print((await api<ProjectView>(`/projects/${pid}/view`)).actions); return; }
    if (arg !== "run" || p.length !== 4) throw usage();
    const start = await api<StartTaskRunResponse>(`/projects/${pid}/actions/${need(p[3])}/runs`, "POST", {});
    const result = await waitTask(start, { noWait: v["no-wait"], follow: v.follow, timeout: numeric(v.timeout, 60), json: jsonOutput });
    print(result.value); process.exitCode = result.code; return;
  }
  if (cmd === "task") {
    if (arg !== "cancel" || p.length !== 3) throw usage();
    print(await api(`/task-runs/${need(third)}/cancel`, "POST", { force: v.force ?? false })); return;
  }
  if (cmd === "status") {
    if (p.length > 2) throw usage();
    print(await api(arg ? `/projects/${need(arg)}/view` : "/projects"));
    return;
  }
  if (p.length !== 2) throw usage();
  const id = need(arg);
  if (v["override-hold"] && !["start", "restart"].includes(cmd)) throw usage();
  if (["start", "stop", "restart", "force-stop"].includes(cmd)) {
    let op = await api<Operation>("/operations", "POST", {
      projectId: arg,
      action: cmd,
      ...(v["override-hold"] ? { overrideHold: true } : {}),
      ...(v.service ? { serviceIds: v.service } : {}),
    });
    if (!v["no-wait"]) op = await wait(op, numeric(v.timeout, 60));
    if (v["wait-ready"]) {
      const { report, code } = await startReport(op, numeric(v["ready-timeout"], 900));
      print(jsonOutput ? report : reportText(report));
      for (const service of report.services) if (service.ready?.state === "not-configured") process.stderr.write(`${service.serviceId} 未配置就绪条件，请自行确认或登记就绪条件\n`);
      process.exitCode = code; return;
    }
    print(op);
    process.exitCode = v["no-wait"] ? 0 : operationCode(op);
    return;
  }
  if (cmd === "policy") { print(await api(`/projects/${id}/policy`)); return; }
  if (cmd === "activity") {
    const query = new URLSearchParams();
    if (v.limit !== undefined) query.set("limit", v.limit);
    print(await api(`/projects/${id}/activity?${query}`)); return;
  }
  if (cmd === "operation") {
    print(await api(`/operations/${id}`));
    return;
  }
  if (cmd === "stats") {
    print(await api(`/projects/${id}/stats`));
    return;
  }
  if (cmd === "logs") {
    if ((v.digest || v["after-seq"] !== undefined) && v.run && v.service?.length) throw usage();
    const view = await api<ProjectView>(`/projects/${id}/view`);
    if ((v.service?.length ?? 0) > 1) throw usage();
    const service =
      v.service?.[0] ??
      (view.services.length === 1 ? view.services[0]?.id : undefined);
    if (!service && !v.run) throw usage();
    let run: RunSummary | TaskRunSummary | undefined;
    if (v.run) {
      try { run = await api<RunSummary>(`/runs/${need(v.run)}`); }
      catch (error) {
        if (!(error instanceof ClientError) || error.body.error.code !== "RUN_NOT_FOUND") throw error;
        run = await api<TaskRunSummary>(`/task-runs/${need(v.run)}`);
      }
    } else { run = (await api<RunSummary[]>(`/projects/${id}/services/${need(service)}/runs`))[0]; }
    if (run && (run.projectId !== arg || (v.service?.[0] && (!("serviceId" in run) || run.serviceId !== v.service[0])))) throw usage();
    if (!run)
      throw new ClientError({
        error: { code: "RUN_NOT_FOUND", message: "没有可读取的运行日志" },
      });
    const tail = numeric(v.tail, v.digest ? 20 : 200);
    if (!Number.isInteger(tail) || tail < (v.digest ? 0 : 1)) throw usage();
    const afterSeq = v["after-seq"] === undefined ? undefined : numeric(v["after-seq"], 0);
    if (afterSeq !== undefined && !Number.isSafeInteger(afterSeq)) throw usage();
    if (v.digest) {
      if (v.follow) throw usage();
      const query = new URLSearchParams();
      if (afterSeq !== undefined) query.set("afterSeq", String(afterSeq));
      if (v["max-bytes"] !== undefined) query.set("maxBytes", v["max-bytes"]);
      if (v.tail !== undefined) query.set("tail", String(tail));
      const result = await api<LogDigest>(`/runs/${run.id}/digest?${query}`);
      print(jsonOutput ? result : digestText(result));
      return;
    }
    const page = await api<LogPage>(`/runs/${run.id}/logs?limit=${tail}${afterSeq === undefined ? "" : `&after=${afterSeq}`}`);
    const show = (line: LogPage["lines"][number]) =>
      process.stdout.write(
        jsonOutput
          ? JSON.stringify(line) + "\n"
          : (line.stream === "sys" ? "devpanel › " : "") + line.text + "\n",
      );
    page.lines.forEach(show);
    if (page.truncated) process.stderr.write("较早日志已按限额截断\n");
    if (v.follow) {
      const res = await raw(
        `/runs/${run.id}/logs/stream?afterSeq=${page.lines.at(-1)?.seq ?? 0}`,
      );
      if ((res.statusCode ?? 500) >= 400) {
        res.resume();
        throw new ClientError({
          error: { code: "RUN_NOT_FOUND", message: "无法订阅运行日志" },
        });
      }
      res.setTimeout(0);
      let pending = "";
      res.setEncoding("utf8");
      for await (const chunk of res) {
        pending += chunk;
        let end: number;
        while ((end = pending.indexOf("\n\n")) >= 0) {
          const block = pending.slice(0, end);
          pending = pending.slice(end + 2);
          const data = block.split("\n").find((x) => x.startsWith("data: "));
          if (!data) continue;
          const ev = JSON.parse(data.slice(6)) as LogStreamEvent;
          if (ev.type === "lines") ev.lines.forEach(show);
          else if (ev.type === "gap")
            process.stderr.write(`日志缺口：${ev.reason}\n`);
          else if (ev.type === "truncated")
            process.stderr.write("较早日志已按限额截断\n");
        }
      }
    }
    return;
  }
  throw usage();
}
try {
  await main();
} catch (e) {
  const body: ErrorBody =
    e instanceof ClientError
      ? e.body
      : {
          error: {
            code: "BAD_REQUEST",
            message: "命令参数无效，请运行 devpanel --help",
          },
        };
  if (jsonOutput) process.stdout.write(JSON.stringify(body) + "\n");
  else process.stderr.write(`${body.error.code}: ${body.error.message}\n`);
  process.exitCode = exitCode(body.error.code);
}
