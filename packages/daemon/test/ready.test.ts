import { trackFixtureProcesses, until } from "./helpers/cleanup.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { startServer } from "../src/server.ts";
import { limits, sleep } from "../src/storage.ts";
import {
  readyIssues,
  readySnapshot,
  logEvidence,
  portEvidence,
} from "../src/ready.ts";
import { uses, inlineParam } from "../src/params.ts";
import type {
  ProjectConfig,
  Operation,
  ReadyConfig,
  LogLine,
} from "@devpanel/contract";
const cfg: ProjectConfig = {
  schemaVersion: 1,
  name: "ready",
  root: "/tmp",
  services: [
    {
      id: "app",
      name: "app",
      cwd: ".",
      command: [process.execPath, "-e", "setInterval(()=>{},1000)"],
    },
  ],
  params: [{ key: "port", label: "Port", type: "number", value: 8080 }],
};
test("就绪配置范围、完整非敏感数字引用、usedBy和number写回", () => {
  const c = structuredClone(cfg);
  c.services[0]!.ready = { check: { kind: "port", port: "${port}" } };
  assert.deepEqual(readyIssues(c.services[0]!.ready, c, "ready"), []);
  assert.deepEqual(uses(c, "port"), [{ serviceId: "app", where: "ready" }]);
  assert.equal(
    (readySnapshot(c, c.services[0]!.ready)!.check as any).port,
    8080,
  );
  inlineParam(c, "port");
  assert.equal((c.services[0]!.ready!.check as any).port, 8080);
  for (const ready of [
    { check: { kind: "log", contains: [] } },
    { check: { kind: "log", contains: ["x".repeat(201)] } },
    { check: { kind: "port", port: 65536 } },
    { check: { kind: "port", port: "80${port}" } },
    { check: { kind: "port" }, timeoutSec: 901 },
  ])
    assert.ok(readyIssues(ready, c, "ready").length);
  c.params![0]!.secret = true;
  assert.equal(
    readyIssues({ check: { kind: "port", port: "${port}" } }, c, "ready")[0]!
      .code,
    "PARAM_INVALID",
  );
  assert.equal(
    readyIssues({ check: { kind: "port", port: "${missing}" } }, c, "ready")[0]!
      .code,
    "PARAM_UNKNOWN",
  );
});
test("ANSI、拆分长行匹配、sys排除及指定/任意端口", () => {
  const tracking = {
    config: { check: { kind: "log", contains: ["READY NOW"] } } as ReadyConfig,
    seq: 0,
    tails: {},
  };
  const line = (
    seq: number,
    text: string,
    partial = false,
    stream: "out" | "sys" = "out",
  ): LogLine => ({ seq, text, partial, stream, ts: "now" });
  assert.equal(logEvidence(tracking, line(1, "READY NOW", false, "sys")), null);
  assert.equal(
    logEvidence(tracking, line(2, "x".repeat(5000) + "\x1b[32mREADY ", true)),
    null,
  );
  assert.deepEqual(logEvidence(tracking, line(3, "NOW\x1b[0m")), {
    kind: "log",
    seq: 3,
  });
  const ports = [
    {
      port: 8080,
      address: "127.0.0.1",
      family: "ipv4" as const,
      pid: 1,
      scope: "loopback" as const,
    },
  ];
  assert.ok(portEvidence({ check: { kind: "port" } }, ports));
  assert.ok(portEvidence({ check: { kind: "port", port: 8080 } }, ports));
  assert.equal(
    portEvidence({ check: { kind: "port", port: 8081 } }, ports),
    null,
  );
});
test("真实服务：就绪、超时不发信号、早退、长轮询和CLI报告", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "dp-ready-"));
  const server = await startServer(home, 0, {
    ...limits,
    startGraceMs: 80,
    statsIntervalMs: 1000,
  });
  const cleanups = [trackFixtureProcesses(server.manager)];
  t.after(async () => {
    try {
      for (const cleanup of cleanups) await cleanup();
    } finally {
      await server.close();
      await rm(home, { recursive: true, force: true });
    }
  });
  const c = structuredClone(cfg);
  c.root = home;
  c.env = {
    TOKEN: { secret: true, value: "ready-env-secret" },
    PARAM: "${hidden}",
  };
  c.params!.push({
    key: "hidden",
    label: "Hidden",
    type: "string",
    value: "ready-param-secret",
    secret: true,
  });
  c.services = [
    {
      id: "log",
      name: "log",
      cwd: ".",
      command: [
        process.execPath,
        "-e",
        "console.log('\\x1b[32mREADY NOW\\x1b[0m');setInterval(()=>{},1000)",
      ],
      ready: { check: { kind: "log", contains: ["READY NOW"] } },
    },
    {
      id: "timeout",
      name: "timeout",
      cwd: ".",
      command: [
        process.execPath,
        "-e",
        "console.error('ERROR '+process.env.TOKEN+' '+process.env.PARAM);setInterval(()=>{},1000)",
      ],
      ready: { check: { kind: "log", contains: ["NEVER"] }, timeoutSec: 1 },
    },
    {
      id: "early",
      name: "early",
      cwd: ".",
      command: [process.execPath, "-e", "process.exit(1)"],
      ready: { check: { kind: "log", contains: ["NEVER"] } },
    },
    { id: "plain", name: "plain", cwd: ".", command: cfg.services[0]!.command },
    {
      id: "waiting",
      name: "waiting",
      cwd: ".",
      command: cfg.services[0]!.command,
      ready: { check: { kind: "log", contains: ["NEVER"] }, timeoutSec: 10 },
    },
  ];
  const p = server.manager.register(c).project;
  const op = server.manager.submit(
    { projectId: p.id, action: "start" },
    { client: "ui", agent: null },
  );
  await until(() => !["queued", "running"].includes(op.state));
  const history = (sid: string) => server.manager.history(p.id, sid)[0]!.detail;
  assert.equal(history("log").ready!.state, "ready");
  assert.equal(history("early").ready!.state, "ended-before-ready");
  assert.equal(history("plain").ready!.state, "not-configured");
  await sleep(1100);
  assert.equal(history("timeout").ready!.state, "timed-out");
  assert.equal(history("timeout").state, "running");
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const cli = join(import.meta.dirname, "../../cli/src/main.ts");
  const result = await promisify(execFile)(
    process.execPath,
    [cli, "start", p.id, "--service", "log", "--wait-ready", "--json"],
    { env: { ...process.env, DEVPANEL_HOME: home }, timeout: 15000 },
  );
  const report = JSON.parse(result.stdout);
  assert.equal(report.services[0].ready.state, "ready");
  assert.ok(report.operation);
  const command = async (sid: string, extra: string[] = []) => {
    try {
      const r = await promisify(execFile)(
        process.execPath,
        [
          cli,
          "start",
          p.id,
          "--service",
          sid,
          "--wait-ready",
          "--json",
          ...extra,
        ],
        { env: { ...process.env, DEVPANEL_HOME: home }, timeout: 15000 },
      );
      return { code: 0, ...r };
    } catch (error: any) {
      return { code: error.code, stdout: error.stdout, stderr: error.stderr };
    }
  };
  const timed = await command("timeout");
  assert.equal(timed.code, 11);
  assert.ok(JSON.parse(timed.stdout).services[0].digest);
  assert.ok(!timed.stdout.includes("ready-env-secret"));
  assert.ok(!timed.stdout.includes("ready-param-secret"));
  assert.equal((await command("early")).code, 1);
  const plain = await command("plain");
  assert.equal(plain.code, 0);
  assert.ok(plain.stderr.includes("未配置"));
  assert.equal((await command("waiting", ["--ready-timeout", "0"])).code, 8);
  assert.equal((await command("waiting", ["--no-wait"])).code, 2);
});

test("端口等待复用采样，达到就绪后停止额外读取；下次使用新选项", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "dp-ready-port-"));
  const server = await startServer(home, 0, {
    ...limits,
    startGraceMs: 50,
    statsIntervalMs: 60000,
  });
  const cleanups = [trackFixtureProcesses(server.manager)];
  t.after(async () => {
    try {
      for (const cleanup of cleanups) await cleanup();
    } finally {
      await server.close();
      await rm(home, { recursive: true, force: true });
    }
  });
  let samples = 0;
  const scanner = (server.manager as any).scanner;
  scanner.listening = async (known: any[]) => {
    samples++;
    return new Map(
      known.map((p) => [
        p.pid,
        samples >= 3
          ? [
              {
                pid: p.pid,
                port: 8080,
                address: "127.0.0.1",
                family: "ipv4",
                scope: "loopback",
              },
            ]
          : [],
      ]),
    );
  };
  const c = structuredClone(cfg);
  c.root = home;
  c.services[0]!.ready = {
    check: { kind: "port", port: "${port}" },
    timeoutSec: 5,
  };
  const p = server.manager.register(c).project;
  const op = server.manager.submit(
    { projectId: p.id, action: "start" },
    { client: "ui", agent: null },
  );
  await until(() => !["queued", "running"].includes(op.state));
  const run = server.manager.history(p.id, "app")[0]!;
  for (let i = 0; i < 100 && run.detail.ready?.state === "waiting"; i++)
    await sleep(30);
  assert.equal(run.detail.ready!.state, "ready");
  const count = samples;
  await sleep(1100);
  assert.equal(samples, count);
  const newer = structuredClone(c);
  newer.params![0]!.value = 9090;
  assert.equal(
    (readySnapshot(newer, newer.services[0]!.ready)!.check as any).port,
    9090,
  );
  // Editing only the ready condition does not change the executed process snapshot.
  const saved = server.manager.projects.get(p.id)!;
  saved.config.services[0]!.ready = {
    check: { kind: "log", contains: ["changed"] },
  };
  assert.equal(
    server.manager.view(p.id).services[0]!.configChangedSinceStart,
    false,
  );
});

test("ready/wait 超时返回当前运行，任务为400；重启不可续接为unknown", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "dp-ready-wait-"));
  let server = await startServer(home, 0, { ...limits, startGraceMs: 50 });
  const cleanups = [trackFixtureProcesses(server.manager)];
  t.after(async () => {
    try {
      for (const cleanup of cleanups) await cleanup();
    } finally {
      await server.close();
      await rm(home, { recursive: true, force: true });
    }
  });
  const c = structuredClone(cfg);
  c.root = home;
  c.services[0]!.ready = {
    check: { kind: "log", contains: ["never"] },
    timeoutSec: 10,
  };
  c.actions = [
    {
      id: "quick",
      name: "quick",
      cwd: ".",
      command: [process.execPath, "-e", "console.error('ERROR task');"],
    },
  ];
  const p = server.manager.register(c).project;
  const op = server.manager.submit(
    { projectId: p.id, action: "start" },
    { client: "ui", agent: null },
  );
  await until(() => !["queued", "running"].includes(op.state));
  const rid = op.results[0]!.runId!;
  const { readFile } = await import("node:fs/promises");
  const discovery = JSON.parse(
    await readFile(join(home, "daemon.json"), "utf8"),
  );
  const get = (path: string) =>
    fetch(`http://127.0.0.1:${server.httpPort}/api/v1${path}`, {
      headers: { Authorization: `Bearer ${discovery.token}` },
    });
  const start = Date.now();
  const response = await get(`/runs/${rid}/ready/wait?timeoutMs=75`);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).ready.state, "waiting");
  assert.ok(Date.now() - start >= 60);
  const task = await server.manager.startAction(p.id, "quick", {
    client: "ui",
    agent: null,
  });
  const bad = await get(`/runs/${task.run.id}/ready/wait?timeoutMs=0`);
  assert.equal(bad.status, 400);
  assert.equal((await bad.json()).error.details.reason, "task-run");
  assert.equal((await get(`/runs/${task.run.id}/digest`)).status, 200);
  await server.close();
  server = await startServer(home, 0, { ...limits, startGraceMs: 50 });
  cleanups.push(trackFixtureProcesses(server.manager));
  assert.equal(server.manager.detail(rid).ready!.state, "unknown");
});
