import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { Activities, configDiff, requestActor } from "../src/activity.ts";
import { Manager, terminal } from "../src/manager.ts";
import { limits, sleep } from "../src/storage.ts";
import {
  stopFixtureProcesses,
  trackFixtureProcesses,
  until,
} from "./helpers/cleanup.ts";
const ui = { client: "ui" as const, agent: null },
  codex = { client: "cli" as const, agent: "codex" };
test("发起方请求头严格校验，界面忽略名称", () => {
  assert.deepEqual(requestActor("cli", "claude-code"), {
    client: "cli",
    agent: "claude-code",
  });
  assert.deepEqual(requestActor("ui", "INVALID !"), ui);
  for (const invalid of [
    "",
    "ABC",
    "a b",
    "-codex",
    "a".repeat(33),
    ["codex", "other"],
  ])
    assert.throws(() => requestActor("cli", invalid));
});
test('工作标识与 URI 编码名称校验；界面忽略工作请求头', () => {
  assert.deepEqual(requestActor('cli', 'codex', 'Task-42', encodeURIComponent('修复中文问题')), { ...codex, taskId: 'Task-42', taskLabel: '修复中文问题' });
  assert.deepEqual(requestActor('ui', 'INVALID', 'a b', '%ZZ'), ui);
  for (const id of ['', '-x', 'a b', 'a'.repeat(65)]) assert.throws(() => requestActor('cli', undefined, id));
  for (const label of ['', '%ZZ', '%0A', 'x'.repeat(121)]) assert.throws(() => requestActor('cli', undefined, 'job', label));
  assert.throws(() => requestActor('cli', undefined, undefined, 'label'));
  const a = new Activities();
  for (let i = 0; i < 8; i++) a.add('p', { ...codex, taskId: i % 2 ? 'a' : 'b' }, { kind: 'policy', change: 'settings', serviceId: null });
  const first = a.page('p', null, 2, 'a');
  assert.equal(first.hasMore, true); assert.equal(first.entries.length, 2);
  assert.ok(first.entries.every(e => e.actor.taskId === 'a'));
  const next = a.page('p', first.entries.at(-1)!.id, 2, 'a');
  assert.equal(next.entries.length, 2); assert.equal(next.hasMore, false);
  assert.equal(a.page('p', a.entries.at(-1)!.id, 2, 'b').entries.length, 2);
});
test("动态敏感差异、截断、保留、分页及游标校验", () => {
  const a = new Activities([], 3);
  const config = {
    env: { TOKEN: { secret: true, value: "super-secret-sentinel-042" } },
    params: [{ key: "token", secret: true, value: "other-private" }],
  };
  const diff = configDiff({}, config);
  assert.equal(
    JSON.stringify(diff).includes("super-secret-sentinel-042"),
    false,
  );
  const before = Object.fromEntries(
    Array.from({ length: 120 }, (_, i) => ["key" + i, i]),
  );
  a.config("p", codex, "update", 1, 2, {}, before);
  const detail = a.entries[0]!.detail;
  assert.equal(detail.kind, "config");
  if (detail.kind === "config") {
    assert.equal(detail.changes.length, 100);
    assert.equal(detail.changesTruncated, true);
  }
  for (let i = 0; i < 4; i++)
    a.add("p", ui, { kind: "policy", change: "settings", serviceId: null });
  assert.equal(a.entries.length, 3);
  const page = a.page("p", null, 2);
  assert.equal(page.hasMore, true);
  assert.equal(a.page("p", page.entries.at(-1)!.id, 2).entries.length, 1);
  assert.throws(() => a.page("p", "missing"));
});
test("服务与任务的启动、停止来源持久化，幂等注册不写动态，删除清空", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "dp-actor-"));
  await mkdir(join(home, "project"));
  let m = new Manager(home, 10, { ...limits, startGraceMs: 80 });
  const cleanup = trackFixtureProcesses(m);
  t.after(async () => {
    try {
      await cleanup();
    } finally {
      await m.close();
      await rm(home, { recursive: true, force: true });
    }
  });
  const settle = async (op: ReturnType<Manager["submit"]>) => {
    await until(() => terminal(op));
    return op;
  };
  try {
    const config = {
      schemaVersion: 1,
      name: "来源",
      root: join(home, "project"),
      env: { TOKEN: { secret: true, value: "super-secret-sentinel-042" } },
      services: [
        {
          id: "web",
          name: "网页",
          cwd: ".",
          command: [
            process.execPath,
            resolve(import.meta.dirname, "fixtures/service.mjs"),
            "silent",
          ],
        },
      ],
      actions: [
        {
          id: "job",
          name: "任务",
          cwd: ".",
          command: [
            process.execPath,
            resolve(import.meta.dirname, "fixtures/service.mjs"),
            "silent",
          ],
        },
      ],
    };
    const pid = m.register(config, codex).project.id;
    const count = m.activity.entries.length;
    m.register(config);
    assert.equal(m.activity.entries.length, count);
    await settle(m.submit({ projectId: pid, action: "start" }, codex));
    assert.deepEqual(m.view(pid).services[0]!.currentRun!.startedBy, codex);
    await settle(m.submit({ projectId: pid, action: "stop" }, ui));
    assert.deepEqual(m.view(pid).services[0]!.lastRun!.exit!.requestedBy, ui);
    await settle(m.submit({ projectId: pid, action: "start" }, ui));
    await settle(m.submit({ projectId: pid, action: "stop" }, codex));
    assert.deepEqual(
      m.view(pid).services[0]!.lastRun!.exit!.requestedBy,
      codex,
    );
    const task = await m.startAction(pid, "job", codex);
    await m.cancelTask(task.run.id, false, false, ui);
    await until(() => !!m.taskDetail(task.run.id).endedAt);
    assert.deepEqual(m.taskDetail(task.run.id).exit!.requestedBy, ui);
    assert.deepEqual(m.taskDetail(task.run.id).startedBy, codex);
    assert.ok(m.activity.entries.some((e) => e.detail.kind === "task-run"));
    assert.equal(
      JSON.stringify(m.activity.entries).includes("super-secret-sentinel-042"),
      false,
    );
    await m.close();
    m = new Manager(home, 10);
    await m.recover();
    assert.deepEqual(
      m.view(pid).services[0]!.lastRun!.exit!.requestedBy,
      codex,
    );
    assert.deepEqual(m.taskDetail(task.run.id).startedBy, codex);
    assert.ok(m.activity.entries.length > 1);
    m.remove(pid);
    assert.equal(m.activity.entries.length, 0);
  } finally {
    await cleanup();
  }
});
test("HTTP agent 校验与 CLI 参数优先级，未配置名称不推断", async () => {
  const { startServer } = await import("../src/server.ts");
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const { readFile } = await import("node:fs/promises");
  const home = await mkdtemp(join(tmpdir(), "dp-agent-http-"));
  const server = await startServer(home, 0);
  try {
    const discovery = JSON.parse(
      await readFile(join(home, "daemon.json"), "utf8"),
    );
    const url = `http://127.0.0.1:${server.httpPort}/api/v1`;
    const headers = {
      Authorization: `Bearer ${discovery.token}`,
      "Content-Type": "application/json",
    };
    assert.equal(
      (
        await fetch(url + "/daemon", {
          headers: {
            ...headers,
            "X-DevPanel-Client": "cli",
            "X-DevPanel-Agent": "INVALID",
          },
        })
      ).status,
      400,
    );
    assert.equal(
      (
        await fetch(url + "/daemon", {
          headers: {
            ...headers,
            "X-DevPanel-Client": "ui",
            "X-DevPanel-Agent": "INVALID",
          },
        })
      ).status,
      200,
    );
    const run = promisify(execFile);
    const cli = resolve(import.meta.dirname, "../../cli/src/main.ts");
    await assert.rejects(
      run(process.execPath, [cli, "status", "--json"], {
        env: { ...process.env, DEVPANEL_HOME: home, DEVPANEL_AGENT: "INVALID" },
      }),
      (e: any) => e.code === 2,
    );
    const value = await run(
      process.execPath,
      [cli, "--agent", "codex", "status", "--json"],
      {
        env: { ...process.env, DEVPANEL_HOME: home, DEVPANEL_AGENT: "INVALID" },
      },
    );
    assert.deepEqual(JSON.parse(value.stdout), []);
  } finally {
    await server.close();
    await rm(home, { recursive: true, force: true });
  }
});

test("差异与幂等比较共用选项元数据规则，不跳过同名环境变量", () => {
  const before = {
    params: [
      {
        key: "token",
        type: "string",
        value: "private",
        secret: true,
        setBy: "user",
      },
    ],
    env: { usedBy: "old" },
  };
  const after = {
    params: [{ ...before.params[0], setBy: "agent", valueUpdatedAt: "now" }],
    env: { usedBy: "new" },
  };
  assert.deepEqual(configDiff(before, after), [
    { path: "env.usedBy", existing: "old", incoming: "new" },
  ]);
});
