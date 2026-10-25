import { test } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtemp,
  mkdir,
  rm,
  writeFile,
  readFile,
  stat,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { request } from "node:http";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { Manager } from "../src/manager.ts";
import { startServer } from "../src/server.ts";
import {
  scanProcesses,
  verifiedSignal,
  resourceSample,
} from "../src/processes.ts";
import { limits, sleep } from "../src/storage.ts";
import type {
  ProjectConfig,
  Operation,
  DaemonDiscovery,
  ProjectView,
  ProjectStats,
  RunDetail,
  LogPage,
  ProcessInfo,
} from "@devpanel/contract";
const exec = promisify(execFile),
  cli = resolve(import.meta.dirname, "../../cli/src/main.ts"),
  fixture = resolve(import.meta.dirname, "fixtures/service.mjs");
import { stopFixtureProcesses } from "./helpers/cleanup.ts";

test('portable CLI export/import previews without execution, requires local inputs and protects revisions/user values', async t => {
  const s = await setup(); t.after(s.cleanup);
  const original = s.config();
  original.env = { TOKEN: { secret: true, value: 'portable-private-token' } };
  original.params = [{ key: 'port', label: 'Port', type: 'number', value: 3000 }];
  const first = (await s.api('/projects', 'POST', original)).data.project;
  const file = join(s.home, 'devpanel.json');
  assert.equal((await s.command('project', 'export', first.id, '--file', file, '--json')).code, 0);
  const text = await readFile(file, 'utf8');
  assert.ok(!text.includes('portable-private-token')); assert.ok(!text.includes(process.execPath));
  assert.notEqual((await s.command('project', 'export', first.id, '--file', file, '--json')).code, 0);
  const document = JSON.parse(text), root2 = join(s.home, 'second'); await mkdir(root2);
  const args = ['project', 'import', '--config', file, '--root', root2, '--json'];
  const missing = await s.command(...args); assert.equal(missing.code, 2);
  assert.equal(JSON.parse(missing.stdout).missingInputs.length, document.inputs.length);
  assert.equal(s.server.manager.projects.size, 1); assert.equal(s.server.manager.runs.size, 0);
  const values: Record<string, string> = {};
  for (const input of document.inputs) values[input.id] = input.kind === 'secret' ? 'new-local-private-token' : input.target.endsWith('/command/0') ? process.execPath : fixture;
  const inputs = join(s.home, 'local.inputs.json'); await writeFile(inputs, JSON.stringify(values));
  const preview = await s.command(...args, '--inputs', inputs);
  assert.equal(preview.code, 0, preview.stdout); assert.equal(JSON.parse(preview.stdout).applied, false);
  assert.ok(!preview.stdout.includes('new-local-private-token')); assert.ok(!preview.stdout.includes(process.execPath));
  assert.equal(s.server.manager.projects.size, 1);
  const applied = await s.command(...args, '--inputs', inputs, '--apply', '--group', 'Demo', '--instance', 'feature'); assert.equal(applied.code, 0, applied.stdout);
  const id = JSON.parse(applied.stdout).projectId;
  assert.deepEqual((await s.api(`/projects/${id}/view`)).data.instance, { group: 'Demo', name: 'feature' });
  assert.equal(s.server.manager.projects.size, 2); assert.equal(s.server.manager.runs.size, 0);
  const noRevision = await s.command(...args, '--inputs', inputs, '--apply'); assert.equal(noRevision.code, 2);
  await s.api(`/projects/${id}/params/port`, 'PATCH', { ifRevision: 1, value: 5000 });
  const conflict = await s.command(...args, '--inputs', inputs, '--apply', '--if-revision', '1');
  assert.equal(JSON.parse(conflict.stdout).error.code, 'REVISION_MISMATCH');
  const protectedValue = await s.command(...args, '--inputs', inputs, '--apply', '--if-revision', '2');
  assert.equal(protectedValue.code, 0, protectedValue.stdout);
  assert.deepEqual(JSON.parse(protectedValue.stdout).keptUserValues, ['port']);
  assert.equal(s.server.manager.project(id).config.params![0]!.value, 5000);
  assert.equal(s.server.manager.runs.size, 0);
});

test('two work contexts and separate directory instances retain independent logs, policy and attribution', async t => {
  const s = await setup(); t.after(s.cleanup);
  const a = s.config('instance-a'), b = s.config('instance-b');
  b.root = join(s.home, 'worktree-b'); await mkdir(b.root);
  a.instance = { group: 'Demo', name: 'main' }; b.instance = { group: 'Demo', name: 'feature' };
  a.env = { TOKEN: { secret: true, value: 'private-work-token' }, SHORT: { secret: true, value: 'xy' } };
  a.actions = [{ id: 'job', name: 'job', cwd: '.', command: [process.execPath, fixture, 'silent'], stopTimeoutSec: 1 }];
  const headers = (task: string, label: string) => ({ 'X-DevPanel-Client': 'cli', 'X-DevPanel-Agent': 'codex', 'X-DevPanel-Task': task, 'X-DevPanel-Task-Label': encodeURIComponent(label) });
  const ha = headers('task-a', '修复 private-work-token xy'), hb = headers('task-b', '并行功能');
  const pa = (await s.api('/projects', 'POST', a, ha)).data.project;
  const pb = (await s.api('/projects', 'POST', b, hb)).data.project;
  assert.notEqual(pa.id, pb.id);
  const starts = await Promise.all([s.api('/operations', 'POST', { projectId: pa.id, action: 'start' }, ha), s.api('/operations', 'POST', { projectId: pb.id, action: 'start' }, hb)]);
  const completed = await Promise.all(starts.map(op => s.wait(op.data.id)));
  assert.ok(completed.every(op => op.state === 'succeeded'));
  const ra = completed[0]!.results[0]!.runId, rb = completed[1]!.results[0]!.runId;
  assert.notEqual(ra, rb);
  assert.equal((await s.api(`/runs/${ra}`)).data.startedBy.taskId, 'task-a');
  assert.equal((await s.api(`/runs/${rb}`)).data.startedBy.taskId, 'task-b');
  assert.ok((await s.api(`/runs/${ra}/logs/search?q=instance-a`)).data.matches.length > 0);
  assert.equal((await s.api(`/runs/${rb}/logs/search?q=instance-a`)).data.matches.length, 0);
  const page = (await s.api(`/projects/${pa.id}/activity?task=task-a&limit=1`)).data;
  assert.equal(page.entries.length, 1); assert.equal(page.hasMore, true);
  assert.equal((await s.api(`/projects/${pa.id}/activity?task=task-b`)).data.entries.length, 0);
  const cliActivity = await s.command('activity', pa.id, '--task', 'task-a', '--json');
  assert.ok(JSON.parse(cliActivity.stdout).entries.every((entry: any) => entry.actor.taskId === 'task-a'));
  const task = (await s.api(`/projects/${pa.id}/actions/job/runs`, 'POST', {}, ha)).data.run;
  assert.equal(task.startedBy.taskId, 'task-a');
  await s.api(`/task-runs/${task.id}/cancel`, 'POST', {}, hb);
  for (let i = 0; i < 100 && !(await s.api(`/task-runs/${task.id}`)).data.endedAt; i++) await sleep(20);
  assert.equal((await s.api(`/task-runs/${task.id}`)).data.exit.requestedBy.taskId, 'task-b');
  await s.action(pa.id, 'stop');
  assert.equal((await s.api(`/projects/${pb.id}/view`)).data.services[0].state, 'running');
  const denied = await s.api('/operations', 'POST', { projectId: pa.id, action: 'start' }, ha);
  const deniedOp = await s.wait(denied.data.id); assert.equal(deniedOp.results[0]!.error!.code, 'POLICY_DENIED');
  const state = JSON.parse(await readFile(join(s.home, 'state.json'), 'utf8'));
  const actors = JSON.stringify([state.activity.map((entry: any) => entry.actor), state.runs.map((run: any) => [run.detail.startedBy, run.detail.exit?.requestedBy, run.task?.actor])]);
  assert.ok(!actors.includes('private-work-token')); assert.ok(!actors.includes('xy')); assert.ok(actors.includes('[REDACTED]'));
  for (const instance of [{ group: '', name: 'x' }, { group: ' ', name: 'x' }, { group: 'x', name: 'a\nb' }, { group: 'x'.repeat(81), name: 'x' }]) assert.equal((await s.api('/config/validate', 'POST', { ...a, instance })).data.ok, false);
  assert.equal((await s.api('/daemon', 'GET', undefined, headers('bad id', 'label'))).status, 400);
  assert.equal((await s.api('/daemon', 'GET', undefined, { ...headers('bad id', 'label'), 'X-DevPanel-Client': 'ui' })).status, 200);
});

async function setup() {
  const home = await mkdtemp(join(tmpdir(), "devpanel-test-"));
  const root = join(home, "project");
  await mkdir(root);
  const server = await startServer(home, 0, {
    ...limits,
    logBytesPerRun: 64 * 1024,
    logBytesGlobal: 256 * 1024,
    logLineMaxBytes: 4096,
    statsIntervalMs: 200,
    startGraceMs: 200,
  });
  const discovery = JSON.parse(
    await readFile(join(home, "daemon.json"), "utf8"),
  ) as DaemonDiscovery;
  const url = `http://127.0.0.1:${server.httpPort}`;
  async function api<T = any>(
    path: string,
    method = "GET",
    data?: unknown,
    headers: Record<string, string> = {},
  ) {
    const res = await fetch(url + "/api/v1" + path, {
      method,
      headers: {
        Authorization: `Bearer ${discovery.token}`,
        "X-DevPanel-Client": "ui",
        "Content-Type": "application/json",
        ...headers,
      },
      body: data === undefined ? undefined : JSON.stringify(data),
    });
    return {
      status: res.status,
      data: res.status === 204 ? null : ((await res.json()) as T),
    };
  }
  async function command(...args: string[]) {
    try {
      const r = await exec(process.execPath, [cli, ...args], {
        env: { ...process.env, DEVPANEL_HOME: home },
        maxBuffer: 1024 ** 2,
      });
      return { code: 0, stdout: r.stdout, stderr: r.stderr };
    } catch (e: any) {
      return {
        code: e.code,
        stdout: e.stdout as string,
        stderr: e.stderr as string,
      };
    }
  }
  const config = (mode = "normal", sid = "backend"): ProjectConfig => ({
    schemaVersion: 1,
    name: "fixture",
    root,
    services: [
      {
        id: sid,
        name: sid,
        cwd: ".",
        command: [process.execPath, fixture, mode],
        stopTimeoutSec: 1,
      },
    ],
  });
  async function wait(id: string) {
    for (let i = 0; i < 100; i++) {
      const { data: op } = await api<Operation>(
        `/operations/${id}/wait?timeoutMs=200`,
      );
      if (!["queued", "running"].includes(op.state)) return op;
    }
    throw new Error("operation did not finish");
  }
  async function action(pid: string, action: string, serviceIds?: string[]) {
    const r = await api<Operation>("/operations", "POST", {
      projectId: pid,
      action,
      ...(serviceIds ? { serviceIds } : {}),
    });
    assert.equal(r.status, 202);
    return wait(r.data.id);
  }
  const cleanup = async () => {
    // Preserve identities before stop mutates run state. HTTP can already be closed
    // on a failed test, and Manager.close() deliberately leaves business processes alive.
    const owned = [...server.manager.runs.values()].flatMap(r => r.known);
    try {
      for (const pid of server.manager.projects.keys()) {
        try { await action(pid, "force-stop"); } catch { /* identity-checked fallback below */ }
      }
      owned.push(...[...server.manager.runs.values()].flatMap(r => r.known));
      await stopFixtureProcesses(owned);
    } finally {
      try { await server.close(); }
      finally { await rm(home, { recursive: true, force: true }); }
    }
  };
  return {
    home,
    root,
    server,
    discovery,
    url,
    api,
    command,
    config,
    wait,
    action,
    cleanup,
  };
}

test("test cleanup removes a silent fixture even after daemon HTTP has closed", async (t) => {
  const s = await setup();
  const owned: import("@devpanel/contract").ProcessInfo[] = [];
  // This independent fallback also makes the red version of the regression safe.
  t.after(async () => {
    await stopFixtureProcesses(owned);
    await s.server.close();
    await rm(s.home, { recursive: true, force: true });
  });
  const project = (await s.api("/projects", "POST", s.config("silent"))).data.project;
  const operation = await s.action(project.id, "start");
  const run = s.server.manager.detail(operation.results[0]!.runId!);
  owned.push(...run.processes);
  assert.equal(owned.length, 1);
  await s.server.close();
  // close intentionally preserves business processes; cleanup must not depend on HTTP.
  assert.equal((await scanProcesses()).get(owned[0]!.pid)?.startedAt, owned[0]!.startedAt);
  await s.cleanup();
  const rows = await scanProcesses();
  assert.ok(owned.every(p => rows.get(p.pid)?.startedAt !== p.startedAt), "silent fixture survives failed HTTP force-stop");
});

test("registration, optimistic update, secrets and validation never spawn; source files survive removal", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const c = s.config("secret");
  c.env = { TEST_TOKEN: { secret: true, value: "sensitive-value-123" } };
  await writeFile(join(s.root, "keep.txt"), "keep");
  assert.equal((await s.api("/config/validate", "POST", c)).data.ok, true);
  const r = await s.api("/projects", "POST", c),
    pid = r.data.project.id;
  assert.equal(r.status, 201);
  assert.equal(r.data.project.config.env.TEST_TOKEN.value, undefined);
  assert.equal(
    (await s.api<ProjectView>(`/projects/${pid}/view`)).data.services[0]?.state,
    "idle",
  );
  assert.equal(s.server.manager.runs.size, 0);
  assert.equal((await s.api("/projects", "POST", c)).data.created, false);
  assert.equal(
    (await s.api("/projects", "POST", { ...c, name: "different" })).status,
    409,
  );
  assert.equal(
    (await s.api(`/projects/${pid}`, "PUT", { ifRevision: 99, config: c })).data
      .error.code,
    "REVISION_MISMATCH",
  );
  const masked = r.data.project.config;
  assert.equal((await s.api("/config/validate", "POST", masked)).data.ok, true);
  assert.equal(
    (await s.api(`/projects/${pid}`, "PUT", { ifRevision: 1, config: masked }))
      .data.revision,
    2,
  );
  assert.equal(s.server.manager.runs.size, 0);
  assert.equal((await s.action(pid, "start")).state, "succeeded");
  assert.equal((await s.api(`/projects/${pid}`, "DELETE")).status, 409);
  const cfg = { ...masked, name: "changed" };
  assert.equal(
    (await s.api(`/projects/${pid}`, "PUT", { ifRevision: 2, config: cfg }))
      .status,
    200,
  );
  const view = (await s.api<ProjectView>(`/projects/${pid}/view`)).data;
  assert.equal(view.services[0]?.configChangedSinceStart, false);
  const logs = await s.api<LogPage>(
    `/runs/${view.services[0]!.currentRun!.id}/logs`,
  );
  assert.ok(logs.data.lines.some((l) => l.text.includes("[REDACTED]")));
  assert.ok(!JSON.stringify(logs).includes("sensitive-value-123"));
  const searched = await s.api(`/runs/${view.services[0]!.currentRun!.id}/logs/search?q=%5BREDACTED%5D&context=1`);
  assert.equal(searched.status, 200);
  assert.ok(searched.data.matches.length > 0);
  assert.ok(!JSON.stringify(searched).includes('sensitive-value-123'));
  assert.equal((await s.api(`/runs/${view.services[0]!.currentRun!.id}/logs/search?q=x&limit=101`)).status, 400);
  assert.equal((await stat(join(s.home, "state.json"))).mode & 0o777, 0o600);
  await s.action(pid, "stop");
  await s.api(`/projects/${pid}`, "DELETE");
  assert.equal(await readFile(join(s.root, "keep.txt"), "utf8"), "keep");
});

test("HTTP/CLI share one run, concurrent starts are idempotent, SSE snapshots and pagination work", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const path = join(s.home, "config.json");
  await writeFile(path, JSON.stringify(s.config()));
  const registered = await s.command(
    "project",
    "register",
    "--config",
    path,
    "--json",
  );
  assert.equal(registered.code, 0, registered.stderr + registered.stdout);
  const pid = JSON.parse(registered.stdout).project.id;
  const controller = new AbortController();
  const stream = await fetch(s.url + "/api/v1/events", {
    headers: { Authorization: `Bearer ${s.discovery.token}` },
    signal: controller.signal,
  });
  const reader = stream.body!.getReader();
  const first = new TextDecoder().decode((await reader.read()).value);
  assert.match(first, /event: snapshot/);
  assert.match(first, new RegExp(pid));
  controller.abort();
  const [ui, cliStart] = await Promise.all([
    s.action(pid, "start"),
    s.command("start", pid, "--json"),
  ]);
  assert.equal(ui.state, "succeeded");
  assert.equal(cliStart.code, 0, cliStart.stdout);
  const cliOp = JSON.parse(cliStart.stdout) as Operation;
  assert.equal(ui.results[0]!.runId, cliOp.results[0]!.runId);
  const runId = ui.results[0]!.runId!;
  assert.equal(
    (await s.api(`/projects/${pid}/services/backend/runs`)).data.length,
    1,
  );
  const status = await s.command("status", pid, "--json");
  assert.equal(JSON.parse(status.stdout).services[0].currentRun.id, runId);
  await sleep(550);
  const stats = (await s.api<ProjectStats>(`/projects/${pid}/stats`)).data;
  assert.ok(stats.total.rssBytes! > 0);
  if (process.platform === "darwin" && process.env.DEVPANEL_PROCESS_BACKEND !== "ps")
    assert.ok(stats.total.footprintBytes! > 0);
  assert.equal(stats.total.status, "ok");
  const page = (await s.api<LogPage>(`/runs/${runId}/logs?limit=2`)).data;
  assert.equal(page.lines.length, 2);
  assert.equal(page.hasMoreBefore, true);
  const before = (
    await s.api<LogPage>(
      `/runs/${runId}/logs?before=${page.lines[0]!.seq}&limit=2`,
    )
  ).data;
  assert.ok(before.lines.at(-1)!.seq < page.lines[0]!.seq);
  const after = (await s.api<LogPage>(`/runs/${runId}/logs?after=0&limit=2`))
    .data;
  assert.equal(after.lines[0]!.seq, 1);
  assert.equal((await s.command("logs", pid, "--tail", "2")).code, 0);
  await s.action(pid, "stop");
  const ended = (await s.api<LogPage>(`/runs/${runId}/logs`)).data;
  assert.equal(ended.runEnded, true);
  const endStream = await fetch(
    s.url + `/api/v1/runs/${runId}/logs/stream?afterSeq=0`,
    { headers: { Authorization: `Bearer ${s.discovery.token}` } },
  );
  assert.match(await endStream.text(), /event: end/);
  const next = await s.action(pid, "start");
  assert.notEqual(next.results[0]!.runId, runId);
});

test("stop timeout remains stopping; force-stop and cancellation during restart", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const pid = (await s.api("/projects", "POST", s.config("ignore"))).data
    .project.id;
  // This regression exercises forced cleanup; v1.3 defaults CLI force-stop to deny.
  await s.api(`/projects/${pid}/policy`, "PUT", {
    holdAfterUserStop: false, agentForceStop: "allow", lockedServices: [],
  });
  await s.action(pid, "start");
  const stop = await s.command("stop", pid, "--json");
  assert.equal(stop.code, 7, stop.stdout);
  const stopResult = JSON.parse(stop.stdout).results[0];
  assert.equal(stopResult.outcome, "stop-timeout");
  assert.deepEqual(stopResult.error.details, { timeoutSec: 1, remaining: 1 });
  const restartTimeout = await s.action(pid, "restart");
  assert.equal(restartTimeout.results[0]?.outcome, "failed");
  assert.equal(restartTimeout.results[0]?.runId, stopResult.runId);
  assert.deepEqual(restartTimeout.results[0]?.error?.details, {
    timeoutSec: 1,
    remaining: 1,
  });
  let view = (await s.api<ProjectView>(`/projects/${pid}/view`)).data;
  assert.equal(view.services[0]?.state, "stopping");
  assert.equal(view.services[0]?.stopTimedOut, true);
  const force = await s.command("force-stop", pid, "--json");
  assert.equal(force.code, 0, force.stdout);
  await s.api(`/projects/${pid}`, "PUT", {
    ifRevision: 1,
    config: s.config("slowstop"),
  });
  await s.action(pid, "start");
  const restart = (
    await s.api<Operation>("/operations", "POST", {
      projectId: pid,
      action: "restart",
    })
  ).data;
  await sleep(100);
  const stopped = await s.action(pid, "stop");
  const old = await s.wait(restart.id);
  assert.equal(old.state, "cancelled");
  assert.ok(old.cancelledBy);
  assert.equal(stopped.state, "succeeded");
  await sleep(400);
  view = (await s.api<ProjectView>(`/projects/${pid}/view`)).data;
  assert.equal(view.services[0]?.state, "stopped");
  assert.equal(
    (await s.api(`/projects/${pid}/services/backend/runs`)).data.length,
    2,
  );
});

test("tracked tree includes detached grandchild; unrelated same-name process is not owned", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const { spawn } = await import("node:child_process");
  const other = spawn(process.execPath, [fixture, "silent"], {
    stdio: "ignore",
  });
  let otherRow: ProcessInfo | undefined;
  const spawned = new Promise<void>((resolve, reject) => {
    other.once("spawn", resolve);
    other.once("error", reject);
  });
  // Install cleanup before awaiting the spawn/identity handshake or making assertions.
  t.after(async () => {
    await spawned;
    if (!otherRow) {
      const candidate = (await scanProcesses()).get(other.pid!);
      if (candidate?.ppid === process.pid && other.exitCode === null && other.signalCode === null) otherRow = candidate;
    }
    if (otherRow) await stopFixtureProcesses([otherRow]);
  });
  await spawned;
  otherRow = (await scanProcesses()).get(other.pid!);
  assert.ok(otherRow, "independent fixture identity must be recorded");
  const c = s.config("tree");
  c.services.push({ ...s.config("normal", "frontend").services[0]! });
  const pid = (await s.api("/projects", "POST", c)).data.project.id;
  const op = await s.action(pid, "start");
  assert.equal(op.state, "succeeded");
  await sleep(600);
  const run = (await s.api<RunDetail>(`/runs/${op.results[0]!.runId}`)).data;
  assert.ok(run.processes.length >= 3, JSON.stringify(run));
  assert.ok(!run.processes.some((p) => p.pid === other.pid));
  const stats = (await s.api<ProjectStats>(`/projects/${pid}/stats`)).data;
  assert.ok(stats.services.backend!.processCount! >= 3);
  assert.equal(
    stats.total.processCount,
    stats.services.backend!.processCount! +
      stats.services.frontend!.processCount!,
  );
  await s.action(pid, "stop", ["backend"]);
  const rows = await scanProcesses();
  for (const p of run.processes)
    assert.notEqual(rows.get(p.pid)?.startedAt, p.startedAt);
  assert.equal(rows.get(other.pid!)?.startedAt, otherRow.startedAt);
  assert.equal(
    (await s.api<ProjectView>(`/projects/${pid}/view`)).data.services[1]?.state,
    "running",
  );
});

test("early exits, vanished command/cwd, independent service failures and failed validation", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  assert.equal(
    (await s.api("/config/validate", "POST", s.config("normal"))).data.ok,
    true,
  );
  const missing = s.config();
  missing.services[0]!.command = ["/does-not-exist"];
  assert.equal((await s.api("/projects", "POST", missing)).status, 422);
  const c = s.config("exit0");
  // Native immediate exits avoid making this lifecycle assertion depend on Node startup under build load.
  c.services[0]!.command = ["/usr/bin/true"];
  c.services.push(s.config("normal", "frontend").services[0]!);
  const pid = (await s.api("/projects", "POST", c)).data.project.id;
  const op = await s.action(pid, "start");
  assert.equal(op.state, "partial");
  assert.equal(op.results[0]?.error?.code, "EXITED_DURING_START");
  const early = (await s.api<RunDetail>(`/runs/${op.results[0]!.runId}`)).data;
  assert.equal(early.state, "exited");
  assert.equal(early.exit?.code, 0);
  await s.action(pid, "stop");
  c.services = [{ ...s.config("exit1").services[0]!, command: ["/usr/bin/false"] }];
  await s.api(`/projects/${pid}`, "PUT", { ifRevision: 1, config: c });
  const failed = await s.action(pid, "start");
  assert.equal(failed.state, "failed");
  await rm(s.root, { recursive: true });
  const invalid = await s.action(pid, "start");
  assert.equal(invalid.state, "failed");
  assert.equal(invalid.results[0]?.error?.code, "CWD_UNAVAILABLE");
});

test("bounded logs preserve stderr, ANSI and long line splitting; retained history limited", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const c = s.config("flood"),
    pid = (await s.api("/projects", "POST", c)).data.project.id;
  const op = await s.action(pid, "start");
  await sleep(500);
  const rid = op.results[0]!.runId!;
  const info = (await s.api<RunDetail>(`/runs/${rid}`)).data;
  assert.equal(info.log.truncated, true);
  assert.ok(info.log.bytes <= 64 * 1024);
  await s.action(pid, "stop");
  await s.server.manager.logs.flush();
  const file = await stat(join(s.home, "logs", rid + ".json"));
  assert.ok(file.size < 66 * 1024);
  const retained = (await s.api<LogPage>(`/runs/${rid}/logs`)).data;
  assert.ok(retained.lines[0]!.seq > 1);
  let revision = 1;
  for (const mode of ["stderr", "ansi", "long"]) {
    await s.api(`/projects/${pid}`, "PUT", {
      ifRevision: revision++,
      config: s.config(mode),
    });
    const start = await s.action(pid, "start");
    await sleep(100);
    await s.action(pid, "stop");
    const page = (await s.api<LogPage>(`/runs/${start.results[0]!.runId}/logs`))
      .data;
    if (mode === "stderr")
      assert.ok(
        page.lines.some((l) => l.stream === "err" && l.text === "stderr-only"),
      );
    if (mode === "ansi")
      assert.ok(page.lines.some((l) => l.text.includes("\x1b[31m")));
    if (mode === "long") {
      assert.ok(page.lines.some((l) => l.partial));
      assert.ok(page.lines.every((l) => Buffer.byteLength(l.text) <= 4096));
    }
  }
  assert.equal(
    (await s.api(`/projects/${pid}/services/backend/runs`)).data.length,
    3,
  );
  assert.equal((await s.api(`/runs/${rid}`)).status, 404);
});

test("HTTP rejects untrusted requests; UI code exchanges once; socket remains private", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  assert.equal((await fetch(s.url + "/api/v1/projects")).status, 401);
  assert.equal(
    (
      await s.api("/projects", "GET", undefined, {
        Origin: "https://evil.example",
      })
    ).status,
    403,
  );
  const wrongHost = await new Promise<number>((resolve, reject) => {
    const req = request(
      s.url + "/api/v1/projects",
      {
        headers: {
          Host: "evil.example",
          Authorization: `Bearer ${s.discovery.token}`,
        },
      },
      (res) => {
        res.resume();
        resolve(res.statusCode!);
      },
    );
    req.on("error", reject);
    req.end();
  });
  assert.equal(wrongHost, 403);
  assert.equal(
    (await s.api("/projects", "POST", s.config(), { "X-DevPanel-Client": "" }))
      .status,
    400,
  );
  assert.equal((await s.api("/auth/ui-code", "POST", {})).status, 401);
  assert.equal((await stat(s.server.socketPath)).mode & 0o777, 0o600);
  const response = await new Promise<{ code: string; url: string }>(
    (resolve, reject) => {
      const req = request(
        {
          socketPath: s.server.socketPath,
          path: "/api/v1/auth/ui-code",
          method: "POST",
          headers: { "X-DevPanel-Client": "cli" },
        },
        (res) => {
          let data = "";
          res.on("data", (c) => (data += c));
          res.on("end", () => resolve(JSON.parse(data)));
        },
      );
      req.on("error", reject);
      req.end("{}");
    },
  );
  const login = await fetch(response.url, { redirect: "manual" });
  assert.equal(login.status, 302);
  const cookie = login.headers.get("set-cookie")!;
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /SameSite=Strict/);
  assert.equal(
    (
      await fetch(s.url + "/api/v1/projects", {
        headers: { Cookie: cookie.split(";")[0]! },
      })
    ).status,
    200,
  );
  assert.equal((await fetch(response.url, { redirect: "manual" })).status, 401);
  assert.equal((await fetch(s.url)).status, 200);
  await assert.rejects(() => startServer(s.home, 0), /已在运行/);
});

test("resource first sample is unknown CPU; PID identity mismatch never receives a signal", async () => {
  const rows = await scanProcesses(),
    self = rows.get(process.pid)!;
  const sample = resourceSample([self], new Map(), Date.now());
  assert.equal(sample.status, "sampling");
  assert.equal(sample.cpuPercent, null);
  assert.equal(resourceSample([], new Map(), Date.now()).cpuPercent, null);
  // A wrong creation time must not signal even this test runner.
  verifiedSignal(
    [{ ...self, startedAt: "1970-01-01T00:00:00.000Z" }],
    rows,
    "SIGKILL",
  );
});

test("standalone daemon survives CLI exit, recovers crash as unknown, blocks duplicate start and stops verified survivor", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "devpanel-life-"));
  const root = join(home, "project");
  await mkdir(root);
  const env = { ...process.env, DEVPANEL_HOME: home, DEVPANEL_PORT: "0" };
  const command = async (...args: string[]) => {
    try {
      const r = await exec(process.execPath, [cli, ...args], { env });
      return { code: 0, stdout: r.stdout };
    } catch (e: any) {
      return { code: e.code, stdout: e.stdout as string };
    }
  };
  const owned: import("@devpanel/contract").ProcessInfo[] = [];
  t.after(async () => {
    await command("daemon", "stop", "--stop-services", "--json");
    await stopFixtureProcesses(owned);
    await rm(home, { recursive: true, force: true });
  });
  assert.equal((await command("daemon", "start", "--json")).code, 0);
  let discovery = JSON.parse(
    await readFile(join(home, "daemon.json"), "utf8"),
  ) as DaemonDiscovery;
  const daemonIdentity = (await scanProcesses()).get(discovery.pid)!;
  owned.push(daemonIdentity);
  await sleep(4200);
  const idle = JSON.parse(
    (await command("daemon", "status", "--json")).stdout,
  ) as import("@devpanel/contract").DaemonInfo;
  assert.equal(idle.self.status, "ok");
  if (process.platform === "darwin" && process.env.DEVPANEL_PROCESS_BACKEND !== "ps") {
    const tool = idle.toolResources!;
    assert.equal(tool.total.status, "ok");
    assert.equal(tool.daemon.processCount, 1);
    assert.equal(tool.helpers.processCount, 1);
    assert.equal(tool.total.processCount, 2);
    assert.equal(tool.total.footprintBytes, tool.daemon.footprintBytes! + tool.helpers.footprintBytes!);
    assert.equal(tool.total.cpuPercent, tool.daemon.cpuPercent! + tool.helpers.cpuPercent!);
    assert.deepEqual(idle.self, tool.daemon);
  }
  t.diagnostic(
    `idle daemon: cpu=${idle.self.cpuPercent?.toFixed(3)}%, rss=${idle.self.rssBytes} bytes`,
  );
  const config: ProjectConfig = {
    schemaVersion: 1,
    name: "crash fixture",
    root,
    services: [
      {
        id: "backend",
        name: "backend",
        cwd: ".",
        command: [process.execPath, fixture, "silent"],
        stopTimeoutSec: 1,
      },
    ],
  };
  const file = join(home, "config.json");
  await writeFile(file, JSON.stringify(config));
  const pid = JSON.parse(
    (await command("project", "register", "--config", file, "--json")).stdout,
  ).project.id;
  const start = JSON.parse(
    (await command("start", pid, "--json")).stdout,
  ) as Operation;
  const runId = start.results[0]!.runId!;
  const view = JSON.parse(
    (await command("status", pid, "--json")).stdout,
  ) as ProjectView;
  const businessIdentity = (await scanProcesses()).get(
    view.services[0]!.currentRun!.pid!,
  )!;
  owned.push(businessIdentity);
  assert.equal((await command("daemon", "stop", "--json")).code, 5);
  verifiedSignal([daemonIdentity], await scanProcesses(), "SIGKILL");
  await sleep(150);
  assert.equal((await command("status", pid, "--json")).code, 3);
  assert.equal(
    (await scanProcesses()).get(businessIdentity.pid)?.startedAt,
    businessIdentity.startedAt,
  );
  assert.equal((await command("daemon", "start", "--json")).code, 0);
  discovery = JSON.parse(await readFile(join(home, "daemon.json"), "utf8"));
  owned.push((await scanProcesses()).get(discovery.pid)!);
  const recovered = JSON.parse(
    (await command("status", pid, "--json")).stdout,
  ) as ProjectView;
  assert.equal(recovered.services[0]!.state, "unknown");
  assert.equal(recovered.services[0]!.currentRun!.id, runId);
  const refused = await command("start", pid, "--json");
  assert.equal(refused.code, 1);
  assert.equal(
    JSON.parse(refused.stdout).results[0].error.code,
    "STATE_UNVERIFIABLE",
  );
  assert.equal((await command("stop", pid, "--json")).code, 0);
  assert.notEqual(
    (await scanProcesses()).get(businessIdentity.pid)?.startedAt,
    businessIdentity.startedAt,
  );
  assert.equal((await command("daemon", "stop", "--json")).code, 0);
  await sleep(200);
  assert.equal((await command("daemon", "start", "--json")).code, 0);
  discovery = JSON.parse(await readFile(join(home, "daemon.json"), "utf8"));
  owned.push((await scanProcesses()).get(discovery.pid)!);
  assert.equal(
    JSON.parse((await command("status", pid, "--json")).stdout).services[0]
      .state,
    "stopped",
  );
});

test("CLI wait timeout is not success; shutdown failure keeps daemon available and blocks racing starts", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const pid = (await s.api("/projects", "POST", s.config("ignore"))).data
    .project.id;
  const pending = await s.command("start", pid, "--timeout", "0", "--json");
  assert.equal(pending.code, 8);
  await s.wait(JSON.parse(pending.stdout).id);
  const noWait = await s.command("start", pid, "--no-wait", "--json");
  assert.equal(noWait.code, 0);
  await s.wait(JSON.parse(noWait.stdout).id);
  const shutting = s.api<Operation>("/daemon/shutdown", "POST", {
    stopServices: true,
  });
  await sleep(50);
  assert.equal(
    (await s.api("/operations", "POST", { projectId: pid, action: "start" }))
      .status,
    409,
  );
  const failed = await shutting;
  assert.equal(failed.data.state, "failed");
  assert.equal(failed.data.results[0]!.outcome, "stop-timeout");
  assert.equal((await s.api("/daemon")).status, 200);
  assert.equal((await s.action(pid, "force-stop")).state, "succeeded");
});

test("standalone validation accepts secret placeholders; saves require existing secrets in the same scope", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const c = s.config();
  c.env = { PROJECT_SECRET: { secret: true } };
  c.services[0]!.env = { SERVICE_SECRET: { secret: true } };
  const validated = await s.api("/config/validate", "POST", c);
  assert.equal(validated.status, 200);
  assert.equal(validated.data.ok, true);
  const rejected = await s.api("/projects", "POST", c);
  assert.equal(rejected.status, 422);
  assert.deepEqual(
    rejected.data.error.details.issues.map((i: any) => i.path),
    ["env.PROJECT_SECRET", "services[0].env.SERVICE_SECRET"],
  );
  c.env.PROJECT_SECRET = { secret: true, value: "project-secret-fixture" };
  c.services[0]!.env.SERVICE_SECRET = {
    secret: true,
    value: "service-secret-fixture",
  };
  const registered = (await s.api("/projects", "POST", c)).data.project;
  const masked = structuredClone(registered.config) as ProjectConfig;
  assert.equal((await s.api("/projects", "POST", masked)).data.created, false);
  assert.equal(
    (
      await s.api(`/projects/${registered.id}`, "PUT", {
        ifRevision: 1,
        config: masked,
      })
    ).status,
    200,
  );
  masked.env!.SERVICE_SECRET = { secret: true };
  masked.services[0]!.env!.PROJECT_SECRET = { secret: true };
  assert.equal((await s.api("/config/validate", "POST", masked)).data.ok, true);
  const update = await s.api(`/projects/${registered.id}`, "PUT", {
    ifRevision: 2,
    config: masked,
  });
  assert.equal(update.status, 422);
  assert.deepEqual(
    update.data.error.details.issues.map((i: any) => i.path),
    ["env.SERVICE_SECRET", "services[0].env.PROJECT_SECRET"],
  );
  const extraService = structuredClone(registered.config) as ProjectConfig;
  extraService.services.push({
    ...s.config("normal", "worker").services[0]!,
    env: { SERVICE_SECRET: { secret: true } },
  });
  const extraRejected = await s.api(`/projects/${registered.id}`, "PUT", {
    ifRevision: 2,
    config: extraService,
  });
  assert.equal(extraRejected.status, 422);
  assert.deepEqual(
    extraRejected.data.error.details.issues.map((i: any) => i.path),
    ["services[1].env.SERVICE_SECRET"],
  );
  // A masked PATH is unknown during standalone validation, not an empty PATH.
  const pathConfig = s.config();
  pathConfig.env = { PATH: { secret: true } };
  pathConfig.services[0]!.command = ["node"];
  assert.equal(
    (await s.api("/config/validate", "POST", pathConfig)).data.ok,
    true,
  );
  assert.equal(s.server.manager.runs.size, 0);
});

test("config change flags compare each service's effective startup snapshot and survive reload", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const c = s.config("silent");
  c.env = {
    SHARED: "initial",
    TOKEN: { secret: true, value: "snapshot-secret-fixture" },
  };
  c.services.push(s.config("silent", "frontend").services[0]!);
  c.services[1]!.env = { SHARED: "override" };
  const registered = (await s.api("/projects", "POST", c)).data.project;
  const pid = registered.id;
  assert.equal((await s.action(pid, "start")).state, "succeeded");
  let revision = 1;
  const flags = async () =>
    (await s.api<ProjectView>(`/projects/${pid}/view`)).data.services.map(
      (v) => v.configChangedSinceStart,
    );
  const save = async (config: ProjectConfig) => {
    const saved = await s.api(`/projects/${pid}`, "PUT", {
      ifRevision: revision,
      config,
    });
    assert.equal(saved.status, 200);
    revision = saved.data.revision;
  };
  await save({ ...registered.config, name: "renamed project" });
  assert.deepEqual(await flags(), [false, false]);
  const edited = structuredClone(c);
  edited.services[0]!.command.push("changed-argument");
  await save(edited);
  assert.deepEqual(await flags(), [true, false]);
  const reloadHome = join(s.home, "reload");
  await mkdir(reloadHome);
  await writeFile(
    join(reloadHome, "state.json"),
    await readFile(join(s.home, "state.json")),
  );
  const restored = new Manager(reloadHome, s.server.manager.boot);
  try {
    assert.deepEqual(
      restored.view(pid).services.map((v) => v.configChangedSinceStart),
      [true, false],
    );
    assert.ok(
      !JSON.stringify(
        restored.detail(restored.view(pid).services[0]!.currentRun!.id),
      ).includes("snapshot-secret-fixture"),
    );
  } finally {
    await restored.close();
  }
  await save(c);
  assert.deepEqual(await flags(), [false, false]);
  const shared = structuredClone(c);
  shared.env!.SHARED = "changed";
  await save(shared);
  assert.deepEqual(await flags(), [true, false]);
  shared.env!.TOKEN = { secret: true, value: "rotated-secret-fixture" };
  await save(shared);
  assert.deepEqual(await flags(), [true, true]);
  await s.action(pid, "restart", ["backend"]);
  assert.deepEqual(await flags(), [false, true]);
  await s.action(pid, "stop");
  assert.deepEqual(await flags(), [false, false]);
});

test("post-start self-exit reports lastRun.exit with no ServiceView.error", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const c = s.config("exit-on-file");
  const pid = (await s.api("/projects", "POST", c)).data.project.id;
  assert.equal((await s.action(pid, "start")).state, "succeeded");
  await writeFile(join(s.root, "exit-now"), "1");
  let service;
  for (let i = 0; i < 100; i++) {
    service = (await s.api<ProjectView>(`/projects/${pid}/view`)).data
      .services[0]!;
    if (!service.currentRun) break;
    await sleep(25);
  }
  assert.equal(service!.state, "failed");
  assert.equal(service!.error, null);
  assert.equal(service!.lastRun?.exit?.reason, "self-exit");
  assert.equal(service!.lastRun?.exit?.code, 1);
});

test("stop timeout details use the startup default and the verified survivors, not the original tree size", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  s.server.manager.limits.defaultStopTimeoutSec = 1;
  const c = s.config("tree-ignore");
  delete c.services[0]!.stopTimeoutSec;
  const pid = (await s.api("/projects", "POST", c)).data.project.id;
  const started = await s.action(pid, "start");
  assert.equal(started.state, "succeeded");
  const rid = started.results[0]!.runId!;
  let count = 0;
  for (let i = 0; i < 100; i++) {
    count = (await s.api<RunDetail>(`/runs/${rid}`)).data.processes.length;
    if (count >= 3) break;
    await sleep(25);
  }
  assert.equal(count, 3);
  c.services[0]!.stopTimeoutSec = 2;
  assert.equal(
    (await s.api(`/projects/${pid}`, "PUT", { ifRevision: 1, config: c }))
      .status,
    200,
  );
  const stopped = await s.action(pid, "stop");
  assert.equal(stopped.results[0]?.outcome, "stop-timeout");
  assert.deepEqual(stopped.results[0]?.error?.details, {
    timeoutSec: 1,
    remaining: 1,
  });
  assert.equal(
    (await s.api<ProjectView>(`/projects/${pid}/view`)).data.services[0]?.error
      ?.code,
    "STOP_TIMEOUT",
  );
  await s.action(pid, "force-stop");
  assert.equal(
    (await s.api<ProjectView>(`/projects/${pid}/view`)).data.services[0]?.error,
    null,
  );
});

test("legacy runs migrate their startup snapshot only when the saved revision is still known", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const pid = (await s.api("/projects", "POST", s.config("silent"))).data
    .project.id;
  await s.action(pid, "start");
  const disk = JSON.parse(await readFile(join(s.home, "state.json"), "utf8"));
  for (const run of disk.runs) delete run.configSnapshot;
  for (const changedRevision of [false, true]) {
    if (changedRevision) disk.projects[0].revision++;
    const home = join(
      s.home,
      changedRevision ? "legacy-changed" : "legacy-same",
    );
    await mkdir(home);
    await writeFile(join(home, "state.json"), JSON.stringify(disk));
    const restored = new Manager(home, s.server.manager.boot);
    try {
      assert.equal(
        restored.view(pid).services[0]?.configChangedSinceStart,
        changedRevision,
      );
    } finally {
      await restored.close();
    }
  }
});

test("stop timeout followed by daemon crash clears the error when recovery confirms exit", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "devpanel-timeout-crash-"));
  const env = { ...process.env, DEVPANEL_HOME: home, DEVPANEL_PORT: "0" };
  const command = (...args: string[]) =>
    exec(process.execPath, [cli, ...args, "--json"], { env });
  const owned: import("@devpanel/contract").ProcessInfo[] = [];
  t.after(async () => {
    await command("daemon", "stop", "--stop-services").catch(() => {});
    await stopFixtureProcesses(owned);
    await rm(home, { recursive: true, force: true });
  });
  const daemon = JSON.parse((await command("daemon", "start")).stdout);
  const daemonIdentity = (await scanProcesses()).get(daemon.pid)!;
  owned.push(daemonIdentity);
  const file = join(home, "config.json");
  await writeFile(
    file,
    JSON.stringify({
      schemaVersion: 1,
      name: "timeout crash",
      root: home,
      services: [
        {
          id: "backend",
          name: "backend",
          cwd: ".",
          command: [process.execPath, fixture, "ignore"],
          stopTimeoutSec: 1,
        },
      ],
    }),
  );
  const pid = JSON.parse(
    (await command("project", "register", "--config", file)).stdout,
  ).project.id;
  await command("start", pid);
  await assert.rejects(command("stop", pid), (e: any) => e.code === 7);
  const before = JSON.parse((await command("status", pid)).stdout).services[0];
  assert.equal(before.state, "stopping");
  assert.equal(before.stopTimedOut, true);
  assert.equal(before.error.code, "STOP_TIMEOUT");
  const businessIdentity = (await scanProcesses()).get(before.currentRun.pid)!;
  owned.push(businessIdentity);
  verifiedSignal([daemonIdentity], await scanProcesses(), "SIGKILL");
  // The writing fixture exits on EPIPE when its daemon's pipe disappears.
  for (let i = 0; i < 100; i++) {
    if (!(await scanProcesses()).has(businessIdentity.pid)) break;
    await sleep(25);
  }
  assert.equal((await scanProcesses()).has(businessIdentity.pid), false);
  const next = JSON.parse((await command("daemon", "start")).stdout);
  owned.push((await scanProcesses()).get(next.pid)!);
  const recovered = JSON.parse((await command("status", pid)).stdout)
    .services[0];
  assert.equal(recovered.state, "failed");
  assert.equal(recovered.currentRun, null);
  assert.equal(recovered.lastRun.id, before.currentRun.id);
  assert.equal(recovered.lastRun.exit.reason, "daemon-lost");
  assert.equal(recovered.stopTimedOut, false);
  assert.equal(recovered.error, null);
  // The cleared error must also survive another disk reload.
  const snapshot = JSON.parse(await readFile(join(home, "state.json"), "utf8"));
  assert.equal(snapshot.runs[0].error, null);
});

test("timeout recovery clears the flag for survivors and clears errors after reboot or legacy terminal reload", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const pid = (await s.api("/projects", "POST", s.config("ignore-silent"))).data
    .project.id;
  await s.action(pid, "start");
  await s.action(pid, "stop");
  const snapshot = JSON.parse(
    await readFile(join(s.home, "state.json"), "utf8"),
  );
  assert.equal(snapshot.runs[0].error.code, "STOP_TIMEOUT");
  for (const scenario of ["survivor", "reboot", "legacy"] as const) {
    const home = join(s.home, scenario);
    await mkdir(home);
    const disk = structuredClone(snapshot);
    if (scenario === "legacy") {
      disk.runs[0].detail.state = "failed";
      disk.runs[0].detail.endedAt = new Date().toISOString();
      disk.runs[0].detail.exit = {
        reason: "daemon-lost",
        code: null,
        signal: null,
        at: disk.runs[0].detail.endedAt,
      };
      disk.runs[0].known = [];
    }
    await writeFile(join(home, "state.json"), JSON.stringify(disk));
    const manager = new Manager(
      home,
      s.server.manager.boot + (scenario === "reboot" ? 60 : 0),
    );
    try {
      await manager.recover();
      const service = manager.view(pid).services[0]!;
      assert.equal(service.stopTimedOut, false);
      if (scenario === "survivor") {
        assert.equal(service.state, "unknown");
        assert.equal(service.error?.code, "STATE_UNVERIFIABLE");
        assert.ok(service.currentRun);
      } else {
        assert.equal(
          service.state,
          scenario === "reboot" ? "stopped" : "failed",
        );
        assert.equal(service.currentRun, null);
        assert.equal(service.error, null);
        assert.equal(service.lastRun?.exit?.reason, "daemon-lost");
      }
    } finally {
      await manager.close();
    }
    if (scenario === "legacy")
      assert.equal(
        JSON.parse(await readFile(join(home, "state.json"), "utf8")).runs[0]
          .error,
        null,
      );
  }
});

test("v0.2 params validate, persist, protect user values, route revisions and CLI", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const config = s.config("silent");
  config.params = [
    {
      key: "port",
      label: "Port",
      type: "number",
      value: 1234,
      min: 1,
      max: 65535,
    },
    { key: "flag", label: "Flag", type: "boolean", value: true },
    {
      key: "profile",
      label: "Profile",
      type: "enum",
      value: "dev",
      choices: [{ value: "dev" }, { value: "prod" }],
    },
  ];
  config.env = { PORT: "${port}", FLAG: "${flag}", PROFILE: "${profile}" };
  const registered = await s.api("/projects", "POST", config, {
    "X-DevPanel-Client": "cli",
  });
  assert.equal(registered.status, 201);
  let project = registered.data.project;
  const id = project.id;
  assert.equal(project.config.params[0].setBy, "agent");
  assert.deepEqual(project.config.params[0].usedBy, [
    { serviceId: "*", where: "env", envKey: "PORT" },
  ]);
  project = (
    await s.api(`/projects/${id}/params/port`, "PATCH", {
      ifRevision: project.revision,
      value: 4321,
    })
  ).data;
  assert.equal(project.config.params[0].setBy, "user");
  assert.equal(
    (
      await s.api(`/projects/${id}/params/port`, "PATCH", {
        ifRevision: 1,
        value: 5,
      })
    ).status,
    409,
  );
  const configFile = join(s.home, "params.json");
  await writeFile(configFile, JSON.stringify(config));
  const updatedCommand = await s.command(
    "project",
    "update",
    id,
    "--config",
    configFile,
    "--if-revision",
    String(project.revision),
    "--json",
  );
  assert.equal(updatedCommand.code, 0);
  const updated = JSON.parse(updatedCommand.stdout);
  assert.deepEqual(updated.keptUserValues, ["port"]);
  assert.equal(updated.config.params[0].value, 4321);
  assert.equal(
    (await s.api("/projects", "POST", config, { "X-DevPanel-Client": "cli" }))
      .data.created,
    false,
  );
  const overridden = await s.command(
    "project",
    "update",
    id,
    "--config",
    configFile,
    "--if-revision",
    String(updated.revision),
    "--override-user-values",
    "--json",
  );
  assert.equal(overridden.code, 0);
  project = JSON.parse(overridden.stdout);
  assert.equal(project.config.params[0].value, 1234);
  assert.equal(project.config.params[0].setBy, "agent");
  assert.equal(s.server.manager.history(id, "backend").length, 0);
  const added = await s.api(`/projects/${id}/params`, "POST", {
    ifRevision: project.revision,
    param: {
      key: "extra",
      label: "Extra",
      type: "string",
      value: "x",
      setBy: "agent",
    },
  });
  assert.equal(added.data.config.params.at(-1).setBy, "user");
  assert.equal(
    (
      await s.api(`/projects/${id}/params`, "POST", {
        ifRevision: added.data.revision,
        param: config.params[0],
      })
    ).data.error.code,
    "CONFIG_CONFLICT",
  );
  assert.equal(
    (await s.command("param", "set", id, "port", "2345", "--json")).code,
    0,
  );
  assert.equal(
    JSON.parse((await s.command("param", "list", id, "--json")).stdout)[0]
      .value,
    2345,
  );
  for (const [key, value] of [
    ["port", "bad"],
    ["port", "70000"],
    ["flag", "yes"],
    ["profile", "staging"],
  ]) {
    const result = await s.command("param", "set", id, key!, value!, "--json");
    assert.equal(result.code, 2);
    assert.equal(JSON.parse(result.stdout).error.code, "PARAM_INVALID");
  }
  assert.equal(
    (await s.command("param", "remove", id, "extra", "--json")).code,
    0,
  );
  assert.match(
    (await s.command("project", "rules", id)).stdout,
    /不要覆盖用户改过的值/,
  );
  const disk = JSON.parse(await readFile(join(s.home, "state.json"), "utf8"));
  assert.equal(disk.projects[0].config.params[0].value, 2345);
  for (const change of [
    (c: ProjectConfig) => {
      c.services[0]!.command.push("${missing}");
    },
    (c: ProjectConfig) => {
      c.params![0]!.value = "bad";
    },
    (c: ProjectConfig) => {
      c.params![0]!.value = 70000;
    },
    (c: ProjectConfig) => {
      c.params![0]!.value = 0;
    },
    (c: ProjectConfig) => {
      c.params![1]!.value = "true";
    },
    (c: ProjectConfig) => {
      c.params![2]!.value = "unknown";
    },
  ]) {
    const c = structuredClone(config);
    change(c);
    const result = await s.api("/config/validate", "POST", c);
    assert.equal(result.data.ok, false);
    assert.ok(
      result.data.issues.some((i: any) =>
        ["PARAM_INVALID", "PARAM_UNKNOWN"].includes(i.code),
      ),
    );
  }
  const unused = structuredClone(config);
  unused.params!.push({
    key: "unused",
    label: "Unused",
    type: "string",
    value: "x",
  });
  assert.ok(
    (await s.api("/config/validate", "POST", unused)).data.issues.some(
      (i: any) => i.code === "WARN_PARAM_UNUSED",
    ),
  );
});

test("v0.2 start substitution, snapshots and effective per-service config changes", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const config = s.config("silent");
  config.params = [
    { key: "text", label: "Text", type: "string", value: "two words" },
    { key: "num", label: "N", type: "number", value: 1e-7 },
    { key: "flag", label: "Flag", type: "boolean", value: false },
  ];
  config.env = {
    PROJECT_VALUE: "${text}",
    ESCAPED: "$${unknown}",
    NUMBER: "${num}",
  };
  config.services[0]!.env = { SERVICE_VALUE: "${flag}" };
  config.services[0]!.command = [
    process.execPath,
    "-e",
    "console.log(JSON.stringify({argv:process.argv.slice(1),env:[process.env.PROJECT_VALUE,process.env.SERVICE_VALUE,process.env.ESCAPED,process.env.NUMBER]}));setInterval(()=>{},1000)",
    "--",
    "prefix=${text}",
    "${num}",
    "${flag}",
    "$${text}",
  ];
  config.services.push({
    ...s.config("silent", "other").services[0]!,
    env: { PROJECT_VALUE: "fixed", NUMBER: "fixed" },
  });
  const id = (await s.api("/projects", "POST", config)).data.project.id;
  const op = await s.action(id, "start");
  assert.equal(op.state, "succeeded");
  const run = (await s.api<RunDetail>(`/runs/${op.results[0]!.runId}`)).data;
  assert.deepEqual(run.command.slice(-4), [
    "prefix=two words",
    "0.0000001",
    "false",
    "${text}",
  ]);
  assert.deepEqual(run.params, { text: "two words", num: 1e-7, flag: false });
  const lines = (await s.api<LogPage>(`/runs/${run.id}/logs`)).data.lines;
  const output = JSON.parse(lines.find((l) => l.stream === "out")!.text);
  assert.deepEqual(output.env, [
    "two words",
    "false",
    "${unknown}",
    "0.0000001",
  ]);
  assert.deepEqual(output.argv, run.command.slice(-4));
  let p = (await s.api(`/projects/${id}`)).data;
  p = (
    await s.api(`/projects/${id}/params/text`, "PATCH", {
      ifRevision: p.revision,
      value: "new",
    })
  ).data;
  let view = (await s.api<ProjectView>(`/projects/${id}/view`)).data;
  assert.deepEqual(
    view.services.map((x) => x.configChangedSinceStart),
    [true, false],
  );
  assert.equal(view.services[0]!.currentRun!.id, run.id);
  await s.api(`/projects/${id}/params/text`, "PATCH", {
    ifRevision: p.revision,
    value: "two words",
  });
  view = (await s.api<ProjectView>(`/projects/${id}/view`)).data;
  assert.deepEqual(
    view.services.map((x) => x.configChangedSinceStart),
    [false, false],
  );
});

test("v0.2 shell values remain single literals in zsh -lc, including quoted placeholders", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const value = "a b'c$HOME; printf INJECTED ${other}";
  const config = s.config();
  config.params = [{ key: "value", label: "Value", type: "string", value }];
  config.services[0]!.command = [
    "/bin/zsh",
    "-lc",
    'printf "%s\\n" ${value} "${value}" \'${value}\'; exec /bin/sleep 30',
  ];
  const id = (await s.api("/projects", "POST", config)).data.project.id;
  let op = await s.action(id, "start");
  assert.equal(op.state, "succeeded");
  const check = async (rid: string) => {
    const page = (await s.api<LogPage>(`/runs/${rid}/logs`)).data;
    assert.deepEqual(
      page.lines.filter((x) => x.stream === "out").map((x) => x.text),
      [value, value, value],
    );
  };
  await check(op.results[0]!.runId!);
  await s.action(id, "stop");
  const project = (await s.api(`/projects/${id}`)).data;
  const result = await s.api(
    `/projects/${id}/params/value?ifRevision=${project.revision}&inline=true`,
    "DELETE",
  );
  assert.equal(result.status, 200);
  op = await s.action(id, "start");
  assert.equal(op.state, "succeeded");
  await check(op.results[0]!.runId!);
});

test("v0.2 deletion and secret boundaries in responses, logs, snapshots and CLI", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const secret = "private-'-$-value";
  const config = s.config("silent");
  config.params = [
    {
      key: "token",
      label: "Token",
      type: "string",
      value: secret,
      secret: true,
    },
    { key: "plain", label: "Plain", type: "string", value: "a ${literal}" },
  ];
  config.env = { TOKEN_VALUE: "prefix-${token}", PLAIN: "${plain}" };
  config.services[0]!.command = [
    process.execPath,
    "-e",
    "console.log(process.argv[1]); console.log(process.env.TOKEN_VALUE);setInterval(()=>{},1000)",
    "--",
    "prefix-${token}",
  ];
  const registered = await s.api("/projects", "POST", config);
  let project = registered.data.project;
  const id = project.id;
  assert.ok(!JSON.stringify(project).includes(secret));
  assert.equal(
    (await s.api("/config/validate", "POST", project.config)).data.ok,
    true,
  );
  const op = await s.action(id, "start");
  assert.equal(op.state, "succeeded");
  const run = (await s.api<RunDetail>(`/runs/${op.results[0]!.runId}`)).data;
  assert.equal(run.command.at(-1), "prefix-••••");
  assert.deepEqual(run.params.token, { secret: true });
  assert.ok(
    !JSON.stringify((await s.api(`/runs/${run.id}/logs`)).data).includes(
      secret,
    ),
  );
  assert.ok(
    !(await s.command("param", "list", id, "--json")).stdout.includes(secret),
  );
  for (const inline of [false, true]) {
    const result = await s.api(
      `/projects/${id}/params/token?ifRevision=${project.revision}&inline=${inline}`,
      "DELETE",
    );
    assert.equal(result.status, 409);
    assert.equal(result.data.error.code, "PARAM_IN_USE");
    if (inline) assert.equal(result.data.error.details.reason, "secret");
  }
  assert.equal(
    (
      await s.api(
        `/projects/${id}/params/plain?ifRevision=${project.revision}&inline=false`,
        "DELETE",
      )
    ).status,
    409,
  );
  project = (
    await s.api(
      `/projects/${id}/params/plain?ifRevision=${project.revision}&inline=true`,
      "DELETE",
    )
  ).data;
  assert.equal(project.config.env.PLAIN, "a $${literal}");
  await s.action(id, "stop");
  project.config.services[0].command = s.config("silent").services[0]!.command;
  project = (
    await s.api(`/projects/${id}`, "PUT", {
      ifRevision: project.revision,
      config: project.config,
    })
  ).data;
  project = (
    await s.api(
      `/projects/${id}/params/token?ifRevision=${project.revision}&inline=true`,
      "DELETE",
    )
  ).data;
  assert.deepEqual(project.config.env.TOKEN_VALUE, { secret: true });
  assert.equal((await s.action(id, "start")).state, "succeeded");
  assert.ok(!JSON.stringify(project).includes(secret));
});

test("v0.2 real LISTEN ports belong only to managed processes and disappear on stop", async (t) => {
  const { createServer } = await import("node:net");
  const s = await setup();
  t.after(s.cleanup);
  const outsider = createServer();
  await new Promise<void>((resolve, reject) => {
    outsider.once("error", reject);
    outsider.listen({ port: 0, host: "::1", ipv6Only: true }, resolve);
  });
  t.after(
    () => new Promise<void>((resolve) => outsider.close(() => resolve())),
  );
  // Keep an IPv4 port occupied too: the managed fixture must allocate its own
  // port atomically, never reuse an outsider's IPv6-only port as a reservation.
  const blocker = createServer();
  await new Promise<void>((resolve, reject) => {
    blocker.once("error", reject);
    blocker.listen(0, "127.0.0.1", resolve);
  });
  t.after(() => new Promise<void>(resolve => blocker.close(() => resolve())));
  const fixture = resolve(import.meta.dirname, "fixtures/listening.mjs");
  const config = s.config("silent");
  config.services = [
    {
      ...config.services[0]!,
      id: "loopback",
      command: [process.execPath, fixture, "127.0.0.1", "0"],
    },
    {
      ...config.services[0]!,
      id: "all",
      command: [process.execPath, fixture, "0.0.0.0"],
    },
    { ...config.services[0]!, id: "none" },
  ];
  const id = (await s.api("/projects", "POST", config)).data.project.id;
  const op = await s.action(id, "start");
  if (op.state !== "succeeded") {
    for (const result of op.results) if (result.runId) {
      const page = (await s.api<LogPage>(`/runs/${result.runId}/logs`)).data;
      t.diagnostic(JSON.stringify({ service: result.serviceId, outcome: result.outcome, logs: page.lines.map(l => l.text) }));
    }
  }
  assert.equal(op.state, "succeeded");
  const startedLogs = (await s.api<LogPage>(`/runs/${op.results[0]!.runId}/logs`)).data;
  const addressLine = startedLogs.lines.find(line => line.text.startsWith('{"address":"127.0.0.1"'));
  assert.ok(addressLine, "fixture reports the actual bound address");
  const port = (JSON.parse(addressLine.text) as { port: number }).port;
  assert.notEqual(port, (blocker.address() as import("node:net").AddressInfo).port);
  let stats: ProjectStats | undefined;
  for (let i = 0; i < 80; i++) {
    stats = (await s.api<ProjectStats>(`/projects/${id}/stats`)).data;
    if (
      stats.services.loopback?.listening?.length &&
      stats.services.all?.listening?.length &&
      stats.services.none?.listening !== null
    )
      break;
    await sleep(100);
  }
  assert.deepEqual(stats!.services.loopback!.listening, [
    {
      port,
      address: "127.0.0.1",
      family: "ipv4",
      scope: "loopback",
      pid: s.server.manager.detail(op.results[0]!.runId!).pid,
    },
  ]);
  assert.equal(stats!.services.all!.listening![0]!.scope, "all");
  assert.equal(stats!.services.all!.listening![0]!.address, "0.0.0.0");
  assert.deepEqual(stats!.services.none!.listening, []);
  assert.ok(!JSON.stringify(stats).includes("::1"));
  const { readListening } = await import("../src/listening.ts");
  const known = op.results.flatMap(
    (r) => s.server.manager.detail(r.runId!).processes,
  );
  const durations: number[] = [];
  for (let i = 0; i < 5; i++) {
    const start = performance.now();
    assert.ok(await readListening(known));
    durations.push(performance.now() - start);
  }
  console.log(
    "v0.2 lsof + identity recheck ms:",
    durations.map((n) => n.toFixed(1)).join(", "),
  );
  assert.equal((await s.action(id, "stop")).state, "succeeded");
  assert.deepEqual(
    (await s.api<ProjectStats>(`/projects/${id}/stats`)).data.services,
    {},
  );
  assert.equal(outsider.listening, true);
  assert.equal(blocker.listening, true);
});

test("clarifications: param routes return contract errors and remain editable with missing cwd/program", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const config = s.config("silent");
  config.params = [{ key: "port", label: "Port", type: "number", value: 1234 }];
  config.services[0]!.env = { PORT: "${port}" };
  const registered = await s.api("/projects", "POST", config);
  let p = registered.data.project;
  const path = `/projects/${p.id}/params`;
  const events: unknown[] = [];
  s.server.manager.on("event", (e) => events.push(e));
  assert.equal((await s.api(`${path}/port`, "DELETE")).status, 400);
  assert.equal(
    (await s.api(`${path}/port`, "DELETE")).data.error.code,
    "BAD_REQUEST",
  );
  for (const method of ["PATCH", "DELETE"]) {
    const result = await s.api(
      `${path}/missing${method === "DELETE" ? `?ifRevision=${p.revision}` : ""}`,
      method,
      method === "PATCH" ? { ifRevision: p.revision, value: 1 } : undefined,
    );
    assert.equal(result.status, 404);
    assert.equal(result.data.error.code, "PARAM_UNKNOWN");
  }
  const inUse = await s.api(`${path}/port?ifRevision=${p.revision}`, "DELETE");
  assert.equal(inUse.status, 409);
  assert.equal(inUse.data.error.code, "PARAM_IN_USE");
  const bin = join(s.root, "temporary-program");
  await writeFile(bin, "#!/bin/sh\nexit 0\n", { mode: 0o700 });
  config.services[0]!.command = [bin];
  p = (
    await s.api(`/projects/${p.id}`, "PUT", { ifRevision: p.revision, config })
  ).data;
  await rm(s.root, { recursive: true });
  for (const method of ["POST", "PATCH"]) {
    const result = await s.api(
      method === "POST" ? path : `${path}/port`,
      method,
      {
        ifRevision: p.revision,
        ...(method === "POST"
          ? {
              param: {
                key: "invalid",
                label: "Invalid",
                type: "number",
                value: "bad",
              },
            }
          : { value: "bad" }),
      },
    );
    assert.equal(result.status, 422);
    assert.equal(result.data.error.code, "CONFIG_INVALID");
    assert.ok(
      result.data.error.details.issues.some(
        (i: any) => i.code === "PARAM_INVALID",
      ),
    );
    assert.ok(
      result.data.error.details.issues.every(
        (i: any) => !["COMMAND_NOT_FOUND", "CWD_UNAVAILABLE"].includes(i.code),
      ),
    );
  }
  const added = await s.api(path, "POST", {
    ifRevision: p.revision,
    param: { key: "extra", label: "Extra", type: "boolean", value: true },
  });
  assert.equal(added.status, 200);
  p = added.data;
  const patched = await s.api(`${path}/port`, "PATCH", {
    ifRevision: p.revision,
    value: 4321,
  });
  assert.equal(patched.status, 200);
  p = patched.data;
  const deleted = await s.api(
    `${path}/port?ifRevision=${p.revision}&inline=true`,
    "DELETE",
  );
  assert.equal(deleted.status, 200);
  p = deleted.data;
  assert.equal(p.config.services[0].env.PORT, "4321");
  assert.equal(s.server.manager.history(p.id, "backend").length, 0);
  assert.equal(
    events.filter((e: any) => e.type === "project.upsert").length,
    4,
  );
  assert.equal(
    JSON.parse(await readFile(join(s.home, "state.json"), "utf8")).projects[0]
      .revision,
    p.revision,
  );
});

test("clarifications: incompatible protected user values reject PUT with 422; POST compares incoming values", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const config = s.config("silent");
  config.params = [
    {
      key: "choice",
      label: "Choice",
      type: "enum",
      choices: [{ value: "user" }, { value: "agent" }],
      value: "user",
    },
    { key: "port", label: "Port", type: "number", value: 50 },
  ];
  const project = (await s.api("/projects", "POST", config)).data.project;
  const malformed = structuredClone(config);
  malformed.params![0]!.value = "agent";
  (malformed.params as unknown[]).push(null);
  const invalid = await s.api("/projects", "POST", malformed, {
    "X-DevPanel-Client": "cli",
  });
  assert.equal(invalid.status, 422);
  assert.equal(invalid.data.error.code, "CONFIG_INVALID");
  for (const change of [
    (c: ProjectConfig) => {
      c.params![0]!.choices = [{ value: "agent" }];
      c.params![0]!.value = "agent";
    },
    (c: ProjectConfig) => {
      c.params![1]!.min = 60;
      c.params![1]!.value = 70;
    },
    (c: ProjectConfig) => {
      c.params![1]!.max = 40;
      c.params![1]!.value = 30;
    },
    (c: ProjectConfig) => {
      c.params![1]!.type = "string";
      c.params![1]!.value = "text";
    },
  ]) {
    const incoming = structuredClone(config);
    change(incoming);
    const result = await s.api(
      `/projects/${project.id}`,
      "PUT",
      { ifRevision: project.revision, config: incoming },
      { "X-DevPanel-Client": "cli" },
    );
    assert.equal(result.status, 422);
    assert.equal(result.data.error.code, "CONFIG_INVALID");
    assert.ok(
      result.data.error.details.issues.some(
        (i: any) =>
          i.code === "PARAM_INVALID" &&
          i.message.includes("overrideUserValues"),
      ),
    );
    const registered = await s.api("/projects", "POST", incoming, {
      "X-DevPanel-Client": "cli",
    });
    assert.equal(registered.status, 409);
    assert.equal(registered.data.error.code, "CONFIG_CONFLICT");
    const unchanged = (await s.api(`/projects/${project.id}`)).data;
    assert.equal(unchanged.revision, project.revision);
    assert.equal(unchanged.config.params[1].value, 50);
  }
  const incoming = structuredClone(config);
  incoming.params![1]!.min = 60;
  incoming.params![1]!.value = 70;
  const overridden = await s.api(
    `/projects/${project.id}`,
    "PUT",
    {
      ifRevision: project.revision,
      config: incoming,
      overrideUserValues: true,
    },
    { "X-DevPanel-Client": "cli" },
  );
  assert.equal(overridden.status, 200);
  assert.equal(overridden.data.config.params[1].value, 70);
});

test("clarifications: per-service run params exclude unused, overridden and secret-env references", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const config = s.config("silent");
  config.params = [
    "command",
    "shared",
    "overridden",
    "sensitive",
    "unused",
    "literal",
  ].map((key) => ({
    key,
    label: key,
    type: "string" as const,
    value: `value-${key}`,
    ...(key === "sensitive" ? { secret: true } : {}),
  }));
  config.env = {
    SHARED: "${shared}",
    OVERRIDDEN: "${overridden}",
    SECRET_TEMPLATE: { secret: true, value: "${literal}" },
  };
  config.services[0]!.command.push("${command}");
  config.services[0]!.env = { OVERRIDDEN: "fixed", SECRET_REF: "${sensitive}" };
  config.services.push(s.config("silent", "other").services[0]!);
  const project = (await s.api("/projects", "POST", config)).data.project;
  const op = await s.action(project.id, "start");
  assert.equal(op.state, "succeeded");
  const first = (await s.api<RunDetail>(`/runs/${op.results[0]!.runId}`)).data;
  const second = (await s.api<RunDetail>(`/runs/${op.results[1]!.runId}`)).data;
  assert.deepEqual(first.params, {
    command: "value-command",
    shared: "value-shared",
    sensitive: { secret: true },
  });
  assert.deepEqual(second.params, {
    shared: "value-shared",
    overridden: "value-overridden",
  });
});

test("clarifications: shell positional arguments and inline secret env preserve literal values", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const value = "space ' $ ; ${text}";
  const config = s.config("silent");
  config.params = [
    { key: "value", label: "Value", type: "string", value },
    {
      key: "secret",
      label: "Secret",
      type: "string",
      secret: true,
      value: "private-value",
    },
    { key: "other", label: "Other", type: "string", value: "plain" },
  ];
  config.env = { TOKEN: "${secret}-${other}" };
  config.services[0]!.command = [
    "/bin/zsh",
    "-lc",
    'printf "%s\\n" ${value} "$0" "$1"; exec /bin/sleep 30',
    "${value}",
    "${value}",
  ];
  let project = (await s.api("/projects", "POST", config)).data.project;
  const id = project.id;
  const check = async () => {
    const op = await s.action(id, "start");
    assert.equal(op.state, "succeeded");
    const run = (await s.api<RunDetail>(`/runs/${op.results[0]!.runId}`)).data;
    assert.deepEqual(run.command.slice(-2), [value, value]);
    await s.action(id, "stop");
    const logs = (await s.api<LogPage>(`/runs/${run.id}/logs`)).data;
    assert.deepEqual(
      logs.lines.filter((l) => l.stream === "out").map((l) => l.text),
      [value, value, value],
    );
  };
  await check();
  project = (
    await s.api(
      `/projects/${id}/params/value?ifRevision=${project.revision}&inline=true`,
      "DELETE",
    )
  ).data;
  await check();
  project = (
    await s.api(
      `/projects/${id}/params/secret?ifRevision=${project.revision}&inline=true`,
      "DELETE",
    )
  ).data;
  assert.deepEqual(project.config.env.TOKEN, { secret: true });
  const stored = s.server.manager.project(id).config;
  assert.deepEqual(stored.env!.TOKEN, {
    secret: true,
    value: "private-value-plain",
  });
  assert.ok(stored.params!.some((p) => p.key === "other"));
});

test("short secret does not corrupt project metadata or validation paths", async (t) => {
  const s = await setup();
  t.after(s.cleanup);
  const config = s.config("silent");
  config.params = [
    {
      key: "secret",
      label: "Secret",
      type: "string",
      secret: true,
      value: "x",
    },
  ];
  config.env = { TEST_SECRET: { secret: true, value: "x" } };
  config.services[0]!.command.push("prefix-${secret}");
  const events: any[] = [];
  s.server.manager.on("event", (e) => events.push(e));
  const created = await s.api("/projects", "POST", config);
  assert.equal(created.status, 201);
  const p = created.data.project;
  assert.equal(p.config.name, "fixture");
  assert.deepEqual(p.config.env.TEST_SECRET, { secret: true });
  assert.equal(p.config.params[0].value, undefined);
  const validation = await s.api("/config/validate", "POST", {
    ...config,
    env: { ...config.env, PATH: "/example/bin" },
  });
  assert.equal(validation.data.services[0].pathUsed, "/example/bin");
  const view = await s.api(`/projects/${p.id}/view`);
  assert.equal(view.data.name, "fixture");
  const op = await s.action(p.id, "start");
  assert.equal(op.state, "succeeded");
  const run = (await s.api<RunDetail>(`/runs/${op.results[0]!.runId}`)).data;
  assert.equal(run.command.at(-1), "prefix-••••");
  assert.ok(
    events
      .filter((e) => e.type === "project.upsert")
      .every((e) => e.project.name === "fixture"),
  );
  const sys = (await s.api<LogPage>(`/runs/${run.id}/logs`)).data.lines.filter(
    (l) => l.stream === "sys",
  );
  assert.ok(sys.every((l) => !l.text.includes("x")));
});

test("ps fallback discovers a short-lived parent’s detached child and stops without residue", async (t) => {
  const previous = process.env.DEVPANEL_PROCESS_BACKEND;
  process.env.DEVPANEL_PROCESS_BACKEND = "ps";
  t.after(() => {
    if (previous === undefined) delete process.env.DEVPANEL_PROCESS_BACKEND;
    else process.env.DEVPANEL_PROCESS_BACKEND = previous;
  });
  const s = await setup();
  t.after(s.cleanup);
  const config = s.config();
  config.services[0]!.command = [process.execPath, resolve(import.meta.dirname, "fixtures/short-parent.mjs")];
  const id = (await s.api("/projects", "POST", config)).data.project.id;
  const op = await s.action(id, "start");
  assert.equal(op.state, "succeeded");
  const runId = op.results[0]!.runId!;
  const seen = new Map<number, import("@devpanel/contract").ProcessInfo>();
  // Independent observation is only for safe fixture cleanup if the assertion fails.
  const root = (await s.api<RunDetail>(`/runs/${runId}`)).data.pid!;
  const until = Date.now() + 2200;
  t.after(async () => verifiedSignal([...seen.values()], await scanProcesses(), "SIGKILL"));
  while (Date.now() < until) {
    for (const row of (await scanProcesses()).values()) if (row.ppid === root) seen.set(row.pid, row);
    await sleep(50);
  }
  assert.equal(seen.size, 1);
  const run = (await s.api<RunDetail>(`/runs/${runId}`)).data;
  const child = [...seen.values()][0]!;
  assert.ok(run.processes.some(p => p.pid === child.pid && p.startedAt === child.startedAt), JSON.stringify(run));
  assert.notEqual((await scanProcesses()).get(child.pid)?.ppid, root, "parent has exited");
  assert.equal((await s.action(id, "stop")).state, "succeeded");
  assert.notEqual((await scanProcesses()).get(child.pid)?.startedAt, child.startedAt);
});
