import { gitTarget, mavenTarget } from "./project-targets.ts";
import {
  createServer,
  type IncomingMessage,
  type ServerResponse,
  type Server,
} from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import {
  chmodSync,
  rmSync,
  mkdirSync,
  readFileSync,
  existsSync,
  statSync,
} from "node:fs";
import { join, resolve, extname, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { uptime } from "node:os";
import type {
  DaemonDiscovery,
  DaemonEvent,
  LogStreamEvent,
  Limits,
} from "@devpanel/contract";
import { requestActor } from "./activity.ts";
import { Manager, terminal, activeStates } from "./manager.ts";
import {
  atomicWrite,
  privateDir,
  Fault,
  now,
  sleep,
  VERSION,
} from "./storage.ts";
import { socketPathError } from "./socket-path.ts";
import { scanProcesses } from "./processes.ts";

const token = () => randomBytes(32).toString("base64url");
const equal = (a: string, b: string) =>
  Buffer.byteLength(a) === Buffer.byteLength(b) &&
  timingSafeEqual(Buffer.from(a), Buffer.from(b));
async function body(req: IncomingMessage): Promise<unknown> {
  let bytes = 0;
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    bytes += chunk.length;
    if (bytes > 1024 ** 2)
      throw new Fault("BAD_REQUEST", "请求体超过 1 MiB", 413);
    chunks.push(chunk);
  }
  try {
    return chunks.length
      ? JSON.parse(Buffer.concat(chunks).toString("utf8"))
      : {};
  } catch {
    throw new Fault("BAD_REQUEST", "JSON 格式错误");
  }
}
function json(res: ServerResponse, status: number, value: unknown) {
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(status === 204 ? undefined : JSON.stringify(value));
}
function sse(res: ServerResponse) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache, no-store",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  res.flushHeaders();
}
function event(res: ServerResponse, value: DaemonEvent | LogStreamEvent) {
  if (res.destroyed || res.writableEnded) return false;
  return res.write(`event: ${value.type}\ndata: ${JSON.stringify(value)}\n\n`);
}
function listen(server: Server, port: number | string): Promise<void> {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    const done = () => {
      server.off("error", reject);
      resolve();
    };
    if (typeof port === "number") server.listen(port, "127.0.0.1", done);
    else server.listen(port, done);
  });
}
async function acquire(home: string, boot: number) {
  const lock = join(home, "run/daemon.lock");
  const rows = await scanProcesses(),
    self = rows.get(process.pid)!;
  const make = () => {
    mkdirSync(lock, { mode: 0o700 });
    atomicWrite(join(lock, "owner.json"), {
      pid: process.pid,
      startedAt: self.startedAt,
      boot,
    });
  };
  try {
    make();
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
    const guard = join(home, "run/recovery.lock");
    try {
      mkdirSync(guard, { mode: 0o700 });
    } catch {
      throw new Error("另一个 daemon 正在启动或恢复锁，请稍后重试");
    }
    try {
      let owner: { pid: number; startedAt: string; boot: number };
      try {
        owner = JSON.parse(readFileSync(join(lock, "owner.json"), "utf8"));
      } catch {
        throw new Error("daemon 锁尚未完成或无法核验；拒绝启动第二实例");
      }
      const fresh = await scanProcesses(),
        p = fresh.get(owner.pid);
      if (Math.abs(owner.boot - boot) <= 5 && p?.startedAt === owner.startedAt)
        throw new Error("daemon 已在运行");
      rmSync(lock, { recursive: true, force: true });
      make();
    } finally {
      rmSync(guard, { recursive: true, force: true });
    }
  }
  return () => rmSync(lock, { recursive: true, force: true });
}
export async function startServer(
  home: string,
  port: number,
  customLimits?: Limits,
) {
  const pathError = socketPathError(home);
  if (pathError)
    throw new Fault(pathError.code, pathError.message, 400, pathError.details);
  process.umask(0o077);
  privateDir(home);
  privateDir(join(home, "run"));
  const boot = Math.round(Date.now() / 1000 - uptime());
  const release = await acquire(home, boot);
  let manager: Manager;
  try {
    manager = new Manager(home, boot, customLimits);
    await manager.recover();
  } catch (e) {
    release();
    throw e;
  }
  const bearer = token(),
    sessions = new Set<string>(),
    codes = new Map<string, number>();
  const socketPath = join(home, "run/devpanel.sock");
  let httpPort = port;
  let closing = false;
  const streams = new Set<ServerResponse>();
  let http: Server, unix: Server;
  const close = async () => {
    if (closing) return;
    closing = true;
    for (const stream of streams) stream.end();
    await manager.close();
    for (const server of [http, unix]) {
      server.closeAllConnections();
      await new Promise<void>((r) => server.close(() => r()));
    }
    rmSync(join(home, "daemon.json"), { force: true });
    rmSync(socketPath, { force: true });
    release();
  };
  const handler =
    (socket: boolean) => async (req: IncomingMessage, res: ServerResponse) => {
      try {
        const url = new URL(req.url || "/", "http://127.0.0.1"),
          path = url.pathname,
          method = req.method || "GET";
        if (!socket) {
          if (
            ![`127.0.0.1:${httpPort}`, `localhost:${httpPort}`].includes(
              req.headers.host || "",
            )
          )
            throw new Fault("FORBIDDEN_ORIGIN", "Host 不被允许", 403);
          if (
            req.headers.origin &&
            ![
              `http://127.0.0.1:${httpPort}`,
              `http://localhost:${httpPort}`,
            ].includes(req.headers.origin)
          )
            throw new Fault("FORBIDDEN_ORIGIN", "Origin 不被允许", 403);
        }
        const actor = requestActor(typeof req.headers["x-devpanel-client"] === "string" ? req.headers["x-devpanel-client"] : undefined, req.headers["x-devpanel-agent"]);
        if (method === "POST" && /^\/api\/v1\/projects\/[^/]+\/git\/(stage|unstage|commit|stash|stash\/apply)$/.test(path) && req.headers["x-devpanel-client"] !== "ui")
          throw new Fault("FORBIDDEN_CLIENT", "Git 写操作只允许界面发起", 403);
        if (
          method !== "GET" &&
          !["ui", "cli"].includes(
            String(req.headers["x-devpanel-client"] || ""),
          )
        )
          throw new Fault("BAD_REQUEST", "缺少 X-DevPanel-Client: ui|cli");
        if (method === "GET" && path === "/auth/exchange") {
          const code = url.searchParams.get("code") || "",
            expires = codes.get(code);
          codes.delete(code);
          if (!expires || expires < Date.now())
            throw new Fault("UNAUTHORIZED", "登录码已过期或已使用", 401);
          const session = token();
          sessions.add(session);
          if (sessions.size > 100)
            sessions.delete(sessions.values().next().value!);
          res.writeHead(302, {
            "Set-Cookie": `devpanel_session=${session}; HttpOnly; SameSite=Strict; Path=/`,
            Location: "/",
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
          });
          res.end();
          return;
        }
        if (method === "GET" && (path === "/" || path.startsWith("/assets/"))) {
          const root = resolve(
            process.env.DEVPANEL_UI_DIR ||
              fileURLToPath(new URL("../../../apps/ui/dist", import.meta.url)),
          );
          const relative =
              path === "/" ? "index.html" : decodeURIComponent(path.slice(1)),
            file = resolve(root, relative);
          if (!file.startsWith(root + sep))
            throw new Fault("BAD_REQUEST", "资源路径无效");
          try {
            const { realpath } = await import("node:fs/promises");
            const realRoot = await realpath(root),
              realFile = await realpath(file);
            if (!realFile.startsWith(realRoot + sep))
              throw new Fault("BAD_REQUEST", "资源路径无效");
            if (!(await stat(realFile)).isFile()) throw new Error("missing");
            const data = await readFile(realFile);
            res.writeHead(200, {
              "Content-Type":
                (
                  {
                    ".html": "text/html; charset=utf-8",
                    ".js": "text/javascript",
                    ".css": "text/css",
                    ".svg": "image/svg+xml",
                    ".png": "image/png",
                    ".woff2": "font/woff2",
                  } as Record<string, string>
                )[extname(file)] || "application/octet-stream",
              "X-Content-Type-Options": "nosniff",
              "Referrer-Policy": "no-referrer",
            });
            res.end(data);
          } catch (e) {
            if (e instanceof Fault) throw e;
            if (path === "/") {
              res.writeHead(200, {
                "Content-Type": "text/html; charset=utf-8",
              });
              res.end(
                '<!doctype html><html lang="zh"><meta charset="utf-8"><title>DevPanel</title><h1>DevPanel 管理服务已启动</h1><p>前端尚未构建。请构建 apps/ui 或设置 DEVPANEL_UI_DIR。</p></html>',
              );
            } else
              json(res, 404, {
                error: { code: "BAD_REQUEST", message: "资源不存在" },
              });
          }
          return;
        }
        if (!socket) {
          const auth = req.headers.authorization || "",
            cookie =
              (req.headers.cookie || "")
                .split(";")
                .map((s) => s.trim())
                .find((s) => s.startsWith("devpanel_session="))
                ?.slice(17) || "";
          if (
            !(auth.startsWith("Bearer ") && equal(auth.slice(7), bearer)) &&
            !sessions.has(cookie)
          )
            throw new Fault("UNAUTHORIZED", "需要本地认证", 401);
        }
        if (!path.startsWith("/api/v1/"))
          throw new Fault("BAD_REQUEST", "路由不存在", 404);
        const route = path.slice(7),
          parts = route.split("/").filter(Boolean).map(decodeURIComponent);
        const reply = (value: unknown, status = 200) =>
          json(res, status, manager.safe(value));
        if (method === "POST" && route === "/auth/ui-code") {
          if (!socket)
            throw new Fault(
              "UNAUTHORIZED",
              "只能通过 Unix socket 获取登录码",
              401,
            );
          for (const [c, t] of codes) if (t < Date.now()) codes.delete(c);
          if (codes.size >= 100) codes.delete(codes.keys().next().value!);
          const code = token();
          codes.set(code, Date.now() + 60000);
          reply({
            code,
            url: `http://127.0.0.1:${httpPort}/auth/exchange?code=${code}`,
          });
          return;
        }
        if (method === "GET" && route === "/daemon") {
          reply(manager.info());
          return;
        }
        if (method === "POST" && route === "/daemon/shutdown") {
          const data = await body(req);
          if (
            !data ||
            typeof data !== "object" ||
            !("stopServices" in data) ||
            typeof data.stopServices !== "boolean"
          )
            throw new Fault("BAD_REQUEST", "stopServices 必须为布尔值");
          const active = [...manager.projects.values()].filter(
            (p) =>
              [...manager.runs.values()].some(
                (r) =>
                  r.detail.projectId === p.id &&
                  activeStates.has(r.detail.state),
              ) ||
              [...manager.operations.values()].some(
                (o) => o.projectId === p.id && !terminal(o),
              ),
          );
          if (active.length && !data.stopServices)
            throw new Fault(
              "PROJECT_RUNNING",
              "仍有运行中服务，需要 --stop-services",
              409,
            );
          manager.shuttingDown = true;
          try { await manager.stopAllTasks(); }
          catch (error) { manager.shuttingDown = false; throw error; }
          const ops = active.map((p) =>
            manager.submit({ projectId: p.id, action: "stop" }, actor, true),
          );
          for (const op of ops) while (!terminal(op)) await sleep(25);
          const failed = ops.find((op) => op.state !== "succeeded");
          reply(failed ?? ops.at(-1) ?? {}, 202);
          if (failed) manager.shuttingDown = false;
          if (!failed)
            setTimeout(() => {
              void close();
            }, 30);
          return;
        }
        if (method === "POST" && route === "/config/validate") {
          reply(manager.validation(await body(req)));
          return;
        }
        if (route === "/projects") {
          if (method === "GET") {
            reply([...manager.projects.keys()].map((id) => manager.view(id)));
            return;
          }
          if (method === "POST") {
            const r = manager.register(await body(req), actor);
            reply(r, r.created ? 201 : 200);
            return;
          }
        }
        if (parts[0] === "projects" && parts[1]) {
          const pid = parts[1];
          manager.project(pid);
          if (parts.length === 3 && parts[2] === "policy") {
            if (method === "GET") { reply(manager.getPolicy(pid)); return; }
            if (method === "PUT") { manager.policies.ui(actor); reply(manager.setPolicy(pid, await body(req), actor)); return; }
          }
          if (parts.length === 5 && parts[2] === "services" && parts[4] === "hold" && method === "DELETE") {
            manager.releaseHold(pid, parts[3]!, actor); reply(null, 204); return;
          }
          if (parts.length === 3 && parts[2] === "activity" && method === "GET") {
            reply(manager.activity.page(pid, url.searchParams.get("before"), Number(url.searchParams.get("limit") ?? 50))); return;
          }
          if (parts[2] === "git") {
            if (manager.shuttingDown) throw new Fault("GIT_FAILED", "管理服务正在关闭", 422);
            const root = gitTarget(manager.project(pid).config, url.searchParams.get("repositoryId") ?? undefined);
            const operation = parts.slice(3).join("/");
            if (method === "GET" && operation === "status") { reply(await (await manager.git).status(root)); return; }
            if (method === "GET" && operation === "stashes") { reply(await (await manager.git).stashes(root)); return; }
            if (method === "GET" && operation === "diff") {
              if (url.searchParams.has("staged") && !["true", "false"].includes(url.searchParams.get("staged")!)) throw new Fault("BAD_REQUEST", "staged 必须为 true 或 false");
              reply(await (await manager.git).diff(root, url.searchParams.get("path"), url.searchParams.get("staged") === "true", url.searchParams.get("context") ?? "3")); return;
            }
            if (method === "POST" && ["stage", "unstage", "commit", "stash", "stash/apply"].includes(operation)) {
              const data = await body(req);
              if (operation === "stage" || operation === "unstage") reply(await (await manager.git).paths(root, data, operation === "stage"));
              else if (operation === "commit") reply(await (await manager.git).commit(root, data));
              else if (operation === "stash") reply(await (await manager.git).stash(root, data));
              else reply(await (await manager.git).apply(root, data));
              return;
            }
          }
          if (parts[2] === "maven") {
            if (parts.length === 3 && method === "GET") { reply(await manager.mavenModel(pid, url.searchParams.get("reload") === "1", url.searchParams.get("mavenProjectId") ?? undefined)); return; }
            if (parts.length === 4 && parts[3] === "runs") {
              if (method === "GET") {
                const target = url.searchParams.get("mavenProjectId");
                if (target !== null) mavenTarget(manager.project(pid).config, target);
                reply(manager.taskHistory(pid, { kind: "maven" }).filter(r => target === null || r.maven?.mavenProjectId === target)); return;
              }
              if (method === "POST") { reply(await manager.startMaven(pid, await body(req), actor), 202); return; }
            }
          }
          if (parts.length === 5 && parts[2] === "actions" && parts[4] === "runs") {
            if (method === "GET") { reply(manager.taskHistory(pid, { kind: "action", actionId: parts[3]! })); return; }
            if (method === "POST") {
              const result = await manager.startAction(pid, parts[3]!, actor);
              reply(result, result.created ? 202 : 200); return;
            }
          }
          if (
            parts[2] === "params" &&
            ((parts.length === 3 && method === "POST") ||
              (parts.length === 4 && ["PATCH", "DELETE"].includes(method)))
          ) {
            if (
              method === "DELETE" &&
              !["true", "false"].includes(
                url.searchParams.get("inline") || "false",
              )
            )
              throw new Fault("BAD_REQUEST", "inline 必须为 true 或 false");
            if (method === "DELETE" && !url.searchParams.has("ifRevision"))
              throw new Fault("BAD_REQUEST", "需要 ifRevision");
            const data =
              method === "DELETE"
                ? { ifRevision: Number(url.searchParams.get("ifRevision")) }
                : await body(req);
            reply(
              manager.param(pid, parts[3], method, data, actor, url.searchParams.get("inline") === "true"),
            );
            return;
          }
          if (parts.length === 2) {
            if (method === "GET") {
              reply(manager.getConfig(pid));
              return;
            }
            if (method === "PUT") {
              reply(
                manager.update(pid, await body(req), actor),
              );
              return;
            }
            if (method === "DELETE") {
              manager.remove(pid);
              reply(null, 204);
              return;
            }
          }
          if (method === "GET" && parts.length === 3 && parts[2] === "view") {
            reply(manager.view(pid));
            return;
          }
          if (method === "GET" && parts.length === 3 && parts[2] === "stats") {
            reply(manager.projectStats(pid));
            return;
          }
          if (
            method === "GET" &&
            parts.length === 5 &&
            parts[2] === "services" &&
            parts[4] === "runs"
          ) {
            reply(
              manager.history(pid, parts[3]!).map((r) => manager.summary(r)),
            );
            return;
          }
        }
        if (parts[0] === "task-runs" && parts[1]) {
          if (parts.length === 2 && method === "GET") { reply(manager.taskDetail(parts[1])); return; }
          if (parts.length === 3 && parts[2] === "cancel" && method === "POST") {
            const data = await body(req);
            if (!data || typeof data !== "object" || ("force" in data && typeof data.force !== "boolean")) throw new Fault("BAD_REQUEST", "force 必须为布尔值");
            const run = await manager.cancelTask(parts[1], "force" in data && data.force === true, false, actor);
            reply(run, run.endedAt ? 200 : 202); return;
          }
        }
        if (route === "/operations" && method === "POST") {
          reply(
            manager.submit(await body(req), actor),
            202,
          );
          return;
        }
        if (parts[0] === "operations" && parts[1] && method === "GET") {
          const op = manager.operation(parts[1]);
          if (parts.length === 3 && parts[2] === "wait") {
            const ms = Number(url.searchParams.get("timeoutMs") ?? 60000);
            if (!Number.isInteger(ms) || ms < 0 || ms > 60000)
              throw new Fault("BAD_REQUEST", "timeoutMs 必须在 0–60000");
            const until = Date.now() + ms;
            while (!terminal(op) && Date.now() < until && !res.destroyed)
              await sleep(Math.min(25, Math.max(1, until - Date.now())));
          } else if (parts.length !== 2)
            throw new Fault("BAD_REQUEST", "路由不存在", 404);
          reply(op);
          return;
        }
        if (parts[0] === "runs" && parts[1] && method === "GET") {
          const rid = parts[1],
            r = manager.run(rid);
          if (parts.length === 2) {
            if (r.task) throw new Fault("RUN_NOT_FOUND", "请从任务运行路由读取任务详情", 404);
            reply(manager.detail(rid));
            return;
          }
          if (parts.length === 4 && parts[2] === "ready" && parts[3] === "wait") {
            if (r.task) throw new Fault("BAD_REQUEST", "任务运行没有就绪条件", 400, { reason: "task-run" });
            const raw = url.searchParams.get("timeoutMs") ?? "60000", ms = Number(raw);
            if (!/^\d+$/.test(raw) || !Number.isInteger(ms) || ms > 60000) throw new Fault("BAD_REQUEST", "timeoutMs 必须在 0–60000");
            const until = Date.now() + ms;
            while (r.detail.ready?.state === "waiting" && Date.now() < until && !res.destroyed) await sleep(Math.min(25, Math.max(1, until-Date.now())));
            reply(manager.summary(r)); return;
          }
          if (parts.length === 3 && parts[2] === "digest") {
            reply(manager.logs.digest(rid, url.searchParams, !!r.detail.endedAt));
            return;
          }
          if (parts.length === 3 && parts[2] === "logs") {
            reply(manager.logs.page(rid, url.searchParams, !!r.detail.endedAt));
            return;
          }
          if (
            parts.length === 4 &&
            parts[2] === "logs" &&
            parts[3] === "stream"
          ) {
            let after = Number(url.searchParams.get("afterSeq") ?? 0);
            if (!Number.isSafeInteger(after) || after < 0)
              throw new Fault("BAD_REQUEST", "afterSeq 必须是非负整数");
            sse(res);
            streams.add(res);
            let blocked = false,
              lastPing = Date.now();
            const gap = (data: { runId: string; reason: string }) => {
              if (data.runId === rid && !blocked)
                event(res, {
                  type: "gap",
                  runId: rid,
                  afterSeq: after,
                  reason: data.reason,
                });
            };
            manager.on("gap", gap);
            if (r.detail.state === "unknown")
              event(res, {
                type: "gap",
                runId: rid,
                afterSeq: after,
                reason: "daemon 重启后无法接续旧日志管道",
              });
            const tick = () => {
              if (blocked) return;
              if (!manager.runs.has(rid)) {
                event(res, {
                  type: "gap",
                  runId: rid,
                  afterSeq: after,
                  reason: "运行已被保留策略删除",
                });
                res.end();
                return;
              }
              const info = manager.logs.info(rid);
              if (info.firstSeq !== null && after < info.firstSeq - 1) {
                event(res, {
                  type: "truncated",
                  runId: rid,
                  firstSeq: info.firstSeq,
                });
                after = info.firstSeq - 1;
              }
              const page = manager.logs.page(
                rid,
                new URLSearchParams({ after: String(after), limit: "500" }),
                !!r.detail.endedAt,
              );
              if (page.lines.length) {
                let expected = after + 1;
                for (const line of page.lines) {
                  if (line.seq > expected) {
                    event(res, {
                      type: "gap",
                      runId: rid,
                      afterSeq: expected - 1,
                      reason: "持久化恢复后存在日志序号缺口",
                    });
                    break;
                  }
                  expected = line.seq + 1;
                }
                after = page.lines.at(-1)!.seq;
                blocked = !event(
                  res,
                  manager.safe({
                    type: "lines",
                    runId: rid,
                    lines: page.lines,
                  }),
                );
              }
              if (
                !page.hasMoreAfter &&
                r.detail.endedAt &&
                !manager.logs.openCollectors.get(rid)
              ) {
                event(res, {
                  type: "end",
                  runId: rid,
                  run: r.task ? manager.taskSummary(r) : manager.summary(r),
                });
                res.end();
              } else if (Date.now() - lastPing >= 10000) {
                blocked = !event(res, { type: "ping", at: now() });
                lastPing = Date.now();
              }
            };
            res.on("drain", () => {
              blocked = false;
            });
            const timer = setInterval(tick, 50);
            res.on("close", () => {
              clearInterval(timer);
              manager.off("gap", gap);
              streams.delete(res);
            });
            tick();
            return;
          }
        }
        if (route === "/events" && method === "GET") {
          sse(res);
          streams.add(res);
          event(res, {
            type: "snapshot",
            daemon: manager.info(),
            projects: [...manager.projects.keys()].map((id) =>
              manager.view(id),
            ),
            operations: [...manager.operations.values()],
            stats: manager.stats,
          });
          const send = (value: DaemonEvent) => {
            if (res.writableLength > 1024 ** 2) {
              res.destroy();
              return;
            }
            event(res, value);
          };
          manager.on("event", send);
          const timer = setInterval(
            () => send({ type: "ping", at: now() }),
            10000,
          );
          res.on("close", () => {
            clearInterval(timer);
            manager.off("event", send);
            streams.delete(res);
          });
          return;
        }
        throw new Fault("BAD_REQUEST", "路由不存在", 404);
      } catch (e) {
        if (res.headersSent) {
          res.end();
          return;
        }
        const fault =
          e instanceof Fault
            ? e
            : new Fault("INTERNAL", "管理服务无法完成此请求", 500);
        json(res, fault.status, manager.safe({ error: fault.error }));
      }
    };
  http = createServer(handler(false));
  unix = createServer(handler(true));
  http.requestTimeout = 10000;
  unix.requestTimeout = 10000;
  try {
    await listen(http, port);
    const address = http.address();
    if (!address || typeof address === "string")
      throw new Error("HTTP 监听失败");
    httpPort = address.port;
    rmSync(socketPath, { force: true });
    await listen(unix, socketPath);
    chmodSync(socketPath, 0o600);
    const discovery: DaemonDiscovery = {
      pid: process.pid,
      version: VERSION,
      apiVersion: 1,
      socketPath,
      httpPort,
      token: bearer,
      startedAt: manager.startedAt,
    };
    atomicWrite(join(home, "daemon.json"), discovery);
  } catch (e) {
    http.close();
    unix.close();
    await manager.close();
    release();
    throw e;
  }
  return { manager, close, httpPort, socketPath };
}
