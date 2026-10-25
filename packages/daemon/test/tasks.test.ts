import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, readFile, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { startServer } from "../src/server.ts";
import { Manager } from "../src/manager.ts";
import { limits, sleep } from "../src/storage.ts";
import { cleanupTaskServer } from "./helpers/cleanup.ts";
import { scanProcesses } from "../src/processes.ts";
import type { ActionConfig, ProjectConfig, TaskRunSummary } from "@devpanel/contract";
const fixture = resolve(import.meta.dirname, "fixtures/service.mjs");
const cli = resolve(import.meta.dirname, "../../cli/src/main.ts");
const exec = promisify(execFile);
async function setup(t: TestContext) {
  const home = await mkdtemp(join(tmpdir(), "dp-task-"));
  const server = await startServer(home, 0, { ...limits, statsIntervalMs: 100, logBytesPerTaskRun: 4096 });
  const m = server.manager;
  const discovery = JSON.parse(await readFile(join(home, "daemon.json"), "utf8"));
  const api = async (path: string, method = "GET", data?: unknown) => {
    const res = await fetch(`http://127.0.0.1:${server.httpPort}/api/v1${path}`, { method, headers: {
      Authorization: `Bearer ${discovery.token}`, "X-DevPanel-Client": "ui", "Content-Type": "application/json",
    }, body: data === undefined ? undefined : JSON.stringify(data) });
    return { status: res.status, data: res.status === 204 ? null : await res.json() };
  };
  t.after(() => cleanupTaskServer(server, home));
  const action = (id: string, mode = "exit0"): ActionConfig => ({ id, name: id, cwd: ".", command: [process.execPath, fixture, mode], stopTimeoutSec: 1 });
  const config = (actions: ActionConfig[]): ProjectConfig => ({ schemaVersion: 1, name: "task fixture", root: home,
    services: [{ id: "server", name: "server", cwd: ".", command: [process.execPath, fixture, "silent"] }], actions });
  async function ended(rid: string): Promise<TaskRunSummary> {
    for (let i = 0; i < 200; i++) { const r = m.taskDetail(rid); if (r.endedAt) return r; await m.refresh(); await sleep(25); }
    throw new Error("task did not end");
  }
  return { home, m, server, api, action, config, ended };
}

test("actions validate and register without execution; current params, secrets and inline references", async t => {
  const s = await setup(t);
  const a = s.action("build");
  a.command = [process.execPath, "-e", "console.log(process.argv[1], process.env.API_TOKEN)", "${mode}"];
  a.env = { API_TOKEN: { secret: true, value: "task-secret-123456" } };
  const c = s.config([a]); c.params = [{ key: "mode", label: "Mode", type: "string", value: "old" }];
  const p = s.m.register(c).project;
  assert.equal(s.m.runs.size, 0);
  assert.equal(p.config.params![0]!.usedBy![0]!.serviceId, "action:build");
  assert.ok(!JSON.stringify(p).includes("task-secret-123456"));
  s.m.param(p.id, "mode", "PATCH", { ifRevision: 1, value: "new ; $value" }, { client: "ui", agent: null });
  const r = await s.m.startAction(p.id, "build", { client: "cli", agent: null });
  assert.equal((await s.ended(r.run.id)).state, "succeeded");
  await sleep(30);
  const logs = s.m.logs.page(r.run.id, new URLSearchParams(), true);
  assert.ok(JSON.stringify(logs).includes("new ; $value"));
  assert.ok(!JSON.stringify(logs).includes("task-secret-123456"));
  assert.equal(s.m.taskDetail(r.run.id).params.mode, "new ; $value");
  s.m.param(p.id, "mode", "DELETE", { ifRevision: 2 }, { client: "ui", agent: null }, true);
  assert.equal(s.m.project(p.id).config.actions![0]!.command.at(-1), "new ; $value");
  const invalid = s.config([{ ...a, timeoutSec: 0 }, a]);
  assert.equal(s.m.validation(invalid).ok, false);
});

test("task concurrency is idempotent per action, independent across actions; deletion protection and stats release", async t => {
  const s = await setup(t);
  const c = s.config([s.action("one", "tree"), s.action("two", "silent")]);
  const p = s.m.register(c).project;
  const starts = await Promise.all(Array.from({ length: 8 }, () => s.m.startAction(p.id, "one", { client: "ui", agent: null })));
  assert.equal(new Set(starts.map(x => x.run.id)).size, 1);
  assert.equal(starts.filter(x => x.created).length, 1);
  const rid = starts[0]!.run.id;
  const two = await s.m.startAction(p.id, "two", { client: "cli", agent: null });
  await sleep(600); await s.m.refresh();
  const processes = s.m.taskDetail(rid).processes;
  assert.ok(processes.length >= 3);
  const stats = s.m.projectStats(p.id);
  assert.equal(Object.keys(stats.tasks).length, 2);
  assert.equal(stats.total.processCount, stats.tasks[rid]!.processCount! + stats.tasks[two.run.id]!.processCount!);
  assert.throws(() => s.m.remove(p.id), e => (e as any).error.code === "TASK_RUNNING");
  assert.throws(() => s.m.update(p.id, { ifRevision: 1, config: { ...c, actions: [] } }), e => (e as any).error.code === "TASK_RUNNING");
  await s.api(`/task-runs/${rid}/cancel`, "POST", {});
  assert.equal((await s.ended(rid)).state, "cancelled");
  const rows = await scanProcesses();
  for (const p of processes) assert.notEqual(rows.get(p.pid)?.startedAt, p.startedAt);
  await s.m.cancelTask(two.run.id, false); await s.ended(two.run.id);
  assert.deepEqual(s.m.projectStats(p.id).tasks, {});
  assert.deepEqual(s.m.stats?.projects, {});
});

test("task cancel timeout, force, execution timeout and retained bounded logs", async t => {
  const s = await setup(t);
  const p = s.m.register(s.config([{ ...s.action("ignore"), command: [process.execPath, "-e", 'process.on("SIGTERM",()=>{}); console.log("ready"); setInterval(()=>{},1000)'] }, { ...s.action("timeout", "silent"), timeoutSec: 1 }, s.action("quick"), s.action("flood", "flood")])).project;
  const ignore = await s.m.startAction(p.id, "ignore", { client: "ui", agent: null });
  for (let i = 0; i < 120 && !s.m.logs.states.get(ignore.run.id)!.lines.some(l => l.text === "ready"); i++) await sleep(25);
  assert.ok(s.m.logs.states.get(ignore.run.id)!.lines.some(l => l.text === "ready"));
  await s.m.cancelTask(ignore.run.id, false); await sleep(1200);
  assert.equal(s.m.taskDetail(ignore.run.id).cancelTimedOut, true);
  assert.equal(s.m.taskDetail(ignore.run.id).state, "cancelling");
  await s.m.cancelTask(ignore.run.id, true); assert.equal((await s.ended(ignore.run.id)).state, "cancelled");
  const timeout = await s.m.startAction(p.id, "timeout", { client: "cli", agent: null });
  const timed = await s.ended(timeout.run.id); assert.equal(timed.state, "timed-out"); assert.equal(timed.exit!.reason, "timeout");
  for (let i = 0; i < 7; i++) await s.ended((await s.m.startAction(p.id, "quick", { client: "cli", agent: null })).run.id);
  assert.equal(s.m.taskHistory(p.id, { kind: "action", actionId: "quick" }).length, 5);
  const flood = await s.m.startAction(p.id, "flood", { client: "cli", agent: null });
  for (let i = 0; i < 120 && !s.m.taskDetail(flood.run.id).log.truncated; i++) await sleep(25);
  await s.m.cancelTask(flood.run.id, false); await s.ended(flood.run.id);
  const log = s.m.taskDetail(flood.run.id).log; assert.ok(log.truncated); assert.ok(log.bytes <= 4096);
});

test("task recovery verifies survivors, vanished identities fail without rerun; spawn failures retain detail", async t => {
  const s = await setup(t);
  const p = s.m.register(s.config([s.action("alive", "silent"), s.action("gone")])).project;
  const alive = await s.m.startAction(p.id, "alive", { client: "cli", agent: null });
  const home = join(s.home, "restored"); await mkdir(home); s.m.save();
  await writeFile(join(home, "state.json"), await readFile(join(s.home, "state.json")));
  const restored = new Manager(home, s.m.boot);
  try {
    await restored.recover();
    assert.equal(restored.taskDetail(alive.run.id).state, "unknown");
    assert.equal((await restored.startAction(p.id, "alive", { client: "ui", agent: null })).created, false);
    await s.m.cancelTask(alive.run.id, false); await s.ended(alive.run.id);
    await restored.recover();
    assert.equal(restored.taskDetail(alive.run.id).exit!.reason, "daemon-lost");
    assert.equal(restored.taskDetail(alive.run.id).state, "failed");
  } finally { await restored.close(); }
  s.m.project(p.id).config.actions![1]!.cwd = "missing";
  const gone = await s.m.startAction(p.id, "gone", { client: "ui", agent: null });
  assert.equal(gone.run.state, "failed"); assert.equal(gone.run.exit!.reason, "spawn-failed");
});

test("CLI action run and logs --run share task output and exit results", async t => {
  const s = await setup(t);
  const p = s.m.register(s.config([s.action("ok"), s.action("bad", "exit1")])).project;
  const command = (...args: string[]) => exec(process.execPath, [cli, ...args], { env: { ...process.env, DEVPANEL_HOME: s.home } });
  const ok = JSON.parse((await command("action", "run", p.id, "ok", "--follow", "--json")).stdout);
  assert.equal(ok.state, "succeeded");
  const discovery = JSON.parse(await readFile(join(s.home, "daemon.json"), "utf8"));
  const stream = await fetch(`http://127.0.0.1:${s.server.httpPort}/api/v1/runs/${ok.id}/logs/stream`, { headers: { Authorization: `Bearer ${discovery.token}` } });
  const events = (await stream.text()).split("\n").filter(l => l.startsWith("data:")).map(l => JSON.parse(l.slice(5)));
  const end = events.find(e => e.type === "end");
  assert.equal(end.run.kind, "action"); assert.equal(end.run.state, "succeeded");
  assert.equal(end.run.serviceId, undefined);
  const logs = await command("logs", p.id, "--run", ok.id, "--json"); assert.ok(logs.stdout.includes("sys"));
  await assert.rejects(command("action", "run", p.id, "bad", "--json"), (e: any) => e.code === 1 && JSON.parse(e.stdout).state === "failed");
  assert.equal((await s.api(`/projects/${p.id}/actions/ok/runs`)).data.length, 1);
  assert.equal((await s.api(`/task-runs/${ok.id}/cancel`, "POST", {})).status, 200);
});

test("natural exit wins when deadline processing waits for identity scan (including exit 0)", async t => {
  for (const code of [0, 7]) {
    const s = await setup(t);
    const gateFile = join(s.home, "exit-now");
    const p = s.m.register(s.config([{ ...s.action("race"), timeoutSec: 1, command: [process.execPath, "-e",
      `const fs=require('fs'); console.log('ready'); setInterval(()=>{if(fs.existsSync(process.argv[1]))process.exit(${code})},10)`, gateFile] }])).project;
    const run = await s.m.startAction(p.id, "race", { client: "ui", agent: null });
    for (let i = 0; i < 100 && !s.m.logs.states.get(run.run.id)!.lines.some(l => l.text === "ready"); i++) await sleep(10);
    const stored = s.m.runs.get(run.run.id)!;
    const child = s.m.children.get(run.run.id)!;
    // Hold both refresh and deadline cancellation before their identity scans finish.
    const scanner = (s.m as any).scanner;
    const scan = scanner.scan.bind(scanner);
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let scans = 0;
    scanner.scan = async () => { scans++; await gate; return scan(); };
    try {
      stored.detail.startedAt = new Date(Date.now() - 2000).toISOString();
      for (let i = 0; i < 100 && !scans; i++) await sleep(10);
      await sleep(300); // timer has entered the timeout path while the process is alive
      const exited = new Promise<void>(resolve => child.once("exit", () => resolve()));
      await writeFile(gateFile, "exit"); await exited;
      release(); scanner.scan = scan;
      const ended = await s.ended(run.run.id);
      assert.equal(ended.exit!.code, code);
      assert.equal(ended.exit!.reason, "self-exit");
      assert.equal(ended.state, code === 0 ? "succeeded" : "failed");
    } finally { release(); scanner.scan = scan; }
  }
});


test("task cleanup closes the server and deletes home even if stopAllTasks fails", async t => {
  const s = await setup(t);
  const p = s.m.register(s.config([s.action("cleanup", "tree")])).project;
  const run = await s.m.startAction(p.id, "cleanup", { client: "ui", agent: null });
  await sleep(300); await s.m.refresh();
  const owned = [...s.m.runs.get(run.run.id)!.known];
  assert.ok(owned.length >= 2);
  const stop = s.m.stopAllTasks.bind(s.m);
  s.m.stopAllTasks = async () => { throw new Error("injected stopAllTasks failure"); };
  try {
    await assert.rejects(cleanupTaskServer(s.server, s.home), /injected stopAllTasks failure/);
    // The registered after hook may repeat cleanup after the fallback already closed everything.
    await cleanupTaskServer(s.server, s.home);
    await assert.rejects(readFile(join(s.home, "daemon.json")), { code: "ENOENT" });
    const rows = await scanProcesses();
    assert.ok(owned.every(p => rows.get(p.pid)?.startedAt !== p.startedAt));
    await assert.rejects(fetch(`http://127.0.0.1:${s.server.httpPort}/api/v1/daemon`));
  } finally { s.m.stopAllTasks = stop; }
});

test("typed task targets isolate same-named services and retain the last finished action", async t => {
  const s = await setup(t);
  const p = s.m.register(s.config([s.action("server"), s.action("maven", "silent")])).project;
  const first = (await s.m.startAction(p.id, "server", { client: "ui", agent: null })).run;
  await s.ended(first.id);
  s.m.project(p.id).config.actions![0]!.command = [process.execPath, fixture, "silent"];
  const next = (await s.m.startAction(p.id, "server", { client: "ui", agent: null })).run;
  const other = (await s.m.startAction(p.id, "maven", { client: "ui", agent: null })).run;
  const view = s.m.view(p.id);
  assert.equal(view.services[0]!.currentRun, null);
  assert.equal(s.m.current(p.id, "server"), undefined);
  assert.equal(view.actions[0]!.currentRun!.id, next.id);
  assert.equal(view.actions[0]!.lastRun!.id, first.id);
  assert.equal(view.actions[1]!.currentRun!.id, other.id);
  assert.equal((await s.api(`/runs/${next.id}`)).status, 404);
  assert.equal((await s.api(`/task-runs/${next.id}`)).data.kind, "action");
});

test("legacy persisted task metadata migrates to typed targets without losing finished history", async t => {
  const s = await setup(t);
  const p = s.m.register(s.config([s.action("legacy")])).project;
  const first = (await s.m.startAction(p.id, "legacy", { client: "ui", agent: null })).run;
  await s.ended(first.id); s.m.save();
  const disk = JSON.parse(await readFile(join(s.home, "state.json"), "utf8"));
  const saved = disk.runs.find((r: any) => r.detail.id === first.id);
  saved.task.kind = "action"; saved.task.actionId = "legacy"; saved.task.maven = null; delete saved.task.target;
  const copy = join(s.home, "legacy-copy"); await mkdir(copy);
  await writeFile(join(copy, "state.json"), JSON.stringify(disk));
  const restored = new Manager(copy, s.m.boot);
  try {
    assert.equal(restored.taskSummary(restored.run(first.id)).actionId, "legacy");
    assert.equal(restored.taskHistory(p.id, { kind: "action", actionId: "legacy" })[0]!.state, "succeeded");
    assert.deepEqual(restored.run(first.id).task!.target, { kind: "action", actionId: "legacy" });
  } finally { await restored.close(); }
});
