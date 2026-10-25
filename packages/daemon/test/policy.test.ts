import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { Operation } from "@devpanel/contract";
import { Manager, terminal } from "../src/manager.ts";
import { startServer } from "../src/server.ts";
import { limits, sleep } from "../src/storage.ts";
import {
  stopFixtureProcesses,
  trackFixtureProcesses,
  until,
} from "./helpers/cleanup.ts";
const ui = { client: "ui" as const, agent: null },
  agent = { client: "cli" as const, agent: "codex" };
const defaults = {
  holdAfterUserStop: true,
  agentForceStop: "deny" as const,
  lockedServices: [] as string[],
};
async function setup(test: import("node:test").TestContext) {
  const home = await mkdtemp(join(tmpdir(), "dp-policy-"));
  await mkdir(join(home, "project"));
  let m = new Manager(home, 12, { ...limits, startGraceMs: 120 });
  const config = {
    schemaVersion: 1,
    name: "托管",
    root: join(home, "project"),
    env: { TOKEN: { secret: true, value: "policy-secret-042" } },
    services: ["a", "b"].map((id) => ({
      id,
      name: id,
      cwd: ".",
      command: [
        process.execPath,
        resolve(import.meta.dirname, "fixtures/service.mjs"),
        "silent",
      ],
      stopTimeoutSec: 1,
    })),
  };
  const pid = m.register(config).project.id;
  const cleanups = [trackFixtureProcesses(m)];
  test.after(async () => {
    try {
      for (const cleanup of cleanups) await cleanup();
    } finally {
      await m.close();
      await rm(home, { recursive: true, force: true });
    }
  });
  const settle = async (op: Operation) => {
    await until(() => terminal(op));
    return op;
  };
  const action = (
    action: string,
    client = "cli",
    serviceIds = ["a"],
    overrideHold = false,
  ) =>
    settle(
      m.submit(
        { projectId: pid, action, serviceIds, overrideHold },
        client === "ui" ? ui : agent,
      ),
    );
  return {
    home,
    config,
    pid,
    get m() {
      return m;
    },
    action,
    settle,
    async reopen() {
      await m.close();
      m = new Manager(home, 12);
      await m.recover();
      cleanups.push(trackFixtureProcesses(m));
    },
    async close() {
      for (const cleanup of cleanups) await cleanup();
    },
  };
}
test("UI 停止建立暂停，CLI 拒绝不创建运行，越过/界面/解除入口准确清除且记录", async (test) => {
  const t = await setup(test);
  try {
    assert.deepEqual(t.m.getPolicy(t.pid), defaults);
    await t.action("start");
    await t.action("stop", "ui");
    const hold = t.m.view(t.pid).services[0]!.hold;
    assert.ok(hold);
    const count = t.m.history(t.pid, "a").length;
    const denied = await t.action("start");
    assert.equal(denied.results[0]!.error!.details!.reason, "hold");
    assert.equal(t.m.history(t.pid, "a").length, count);
    const overridden = await t.action("start", "cli", ["a"], true);
    assert.equal(overridden.state, "succeeded");
    assert.equal(t.m.view(t.pid).services[0]!.hold, null);
    assert.ok(
      t.m.activity.entries.some(
        (e) =>
          e.detail.kind === "operation" &&
          e.detail.operationId === overridden.id &&
          e.detail.overrideHold,
      ),
    );
    await t.action("stop", "ui");
    await t.action("start", "ui");
    assert.equal(t.m.view(t.pid).services[0]!.hold, null);
    await t.action("stop", "ui");
    t.m.releaseHold(t.pid, "a", ui);
    assert.equal((await t.action("start")).state, "succeeded");
    await t.action("stop");
    assert.equal(t.m.view(t.pid).services[0]!.hold, null);
    assert.equal(
      JSON.stringify(t.m.activity.entries).includes("policy-secret-042"),
      false,
    );
  } finally {
    await t.close();
  }
});
test("锁定拒绝 CLI 四种动作和 override，UI 不受限；强停开关两值", async (test) => {
  const t = await setup(test);
  try {
    t.m.setPolicy(t.pid, { ...defaults, lockedServices: ["a"] }, ui);
    for (const cmd of ["start", "stop", "restart", "force-stop"]) {
      const denied = await t.action(cmd, "cli", ["a"], true);
      assert.equal(denied.results[0]!.error!.details!.reason, "locked");
    }
    assert.equal(t.m.history(t.pid, "a").length, 0);
    assert.equal((await t.action("start", "ui")).state, "succeeded");
    t.m.setPolicy(t.pid, defaults, ui);
    const live = t.m.view(t.pid).services[0]!.currentRun!.id;
    assert.equal(
      (await t.action("force-stop")).results[0]!.error!.details!.reason,
      "force-stop",
    );
    assert.equal(t.m.view(t.pid).services[0]!.currentRun!.id, live);
    t.m.setPolicy(t.pid, { ...defaults, agentForceStop: "allow" }, ui);
    assert.equal((await t.action("force-stop")).state, "succeeded");
    assert.equal(t.m.view(t.pid).services[0]!.hold, null);
    assert.throws(() =>
      t.m.setPolicy(t.pid, { ...defaults, lockedServices: ["missing"] }, ui),
    );
    assert.throws(
      () => t.m.setPolicy(t.pid, defaults, agent),
      (e: any) => e.status === 403,
    );
    assert.throws(
      () => t.m.releaseHold(t.pid, "a", agent),
      (e: any) => e.status === 403,
    );
  } finally {
    await t.close();
  }
});
test("拒绝 stop 不取消已排队 start；UI stop 与 CLI start 竞态在执行前再检查暂停", async (test) => {
  const t = await setup(test);
  try {
    // Occupy this service queue without starting a process.
    let release!: () => void;
    t.m.queues.set(
      `${t.pid}/a`,
      new Promise<void>((r) => {
        release = r;
      }),
    );
    const start = t.m.submit(
      { projectId: t.pid, serviceIds: ["a"], action: "start" },
      agent,
    );
    t.m.setPolicy(t.pid, { ...defaults, lockedServices: ["a"] }, ui);
    const stop = t.m.submit(
      { projectId: t.pid, serviceIds: ["a"], action: "stop" },
      agent,
    );
    t.m.setPolicy(t.pid, defaults, ui);
    release();
    await t.settle(start);
    await t.settle(stop);
    assert.equal(start.state, "succeeded");
    assert.equal(start.cancelledBy, null);
    assert.equal(stop.results[0]!.error!.code, "POLICY_DENIED");
    const uiStop = t.m.submit(
      { projectId: t.pid, serviceIds: ["a"], action: "stop" },
      ui,
    );
    const racingStart = t.m.submit(
      { projectId: t.pid, serviceIds: ["a"], action: "start" },
      agent,
    );
    await t.settle(uiStop);
    await t.settle(racingStart);
    assert.equal(racingStart.results[0]!.error!.details!.reason, "hold");
    assert.equal(t.m.history(t.pid, "a").length, 1);
    assert.equal(t.m.current(t.pid, "a"), undefined);
  } finally {
    await t.close();
  }
});
test("暂停/规则重启保留，关闭停止后暂停清空；删服务清除锁且配置不写规则", async (test) => {
  const t = await setup(test);
  try {
    await t.action("start", "ui");
    await t.action("stop", "ui");
    const hold = t.m.view(t.pid).services[0]!.hold;
    t.m.setPolicy(t.pid, { ...defaults, lockedServices: ["b"] }, ui);
    await t.reopen();
    assert.deepEqual(t.m.view(t.pid).services[0]!.hold, hold);
    assert.deepEqual(t.m.getPolicy(t.pid).lockedServices, ["b"]);
    t.m.setPolicy(
      t.pid,
      { ...defaults, holdAfterUserStop: false, lockedServices: ["b"] },
      ui,
    );
    assert.equal(t.m.view(t.pid).services[0]!.hold, null);
    const p = t.m.project(t.pid);
    t.m.update(t.pid, {
      ifRevision: p.revision,
      config: { ...t.config, policy: defaults },
    });
    assert.equal(t.m.getPolicy(t.pid).holdAfterUserStop, false);
    t.m.setPolicy(t.pid, { ...defaults, lockedServices: ["b"] }, ui);
    await t.action("start", "ui", ["b"]);
    await t.action("stop", "ui", ["b"]);
    const before = t.m.activity.entries.length;
    t.m.update(
      t.pid,
      {
        ifRevision: t.m.project(t.pid).revision,
        config: { ...t.config, services: [t.config.services[0]] },
      },
      agent,
    );
    assert.deepEqual(t.m.getPolicy(t.pid).lockedServices, []);
    const pruned = t.m.activity.entries
      .slice(before)
      .filter((e) => e.detail.kind === "policy");
    assert.deepEqual(
      pruned.map((e) => e.detail.kind === "policy" && e.detail.change).sort(),
      ["release", "unlock"],
    );
    assert.ok(
      pruned.every(
        (e) =>
          e.actor.agent === "codex" &&
          e.detail.kind === "policy" &&
          e.detail.serviceId === "b",
      ),
    );
  } finally {
    await t.close();
  }
});
test("HTTP CLI 写规则/解除暂停 403；CLI policy 与退出码 12、6", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "dp-policy-http-"));
  await mkdir(join(home, "project"));
  const s = await startServer(home, 0, { ...limits, startGraceMs: 60 });
  const cleanup = trackFixtureProcesses(s.manager);
  t.after(async () => {
    try {
      await cleanup();
    } finally {
      await s.close();
      await rm(home, { recursive: true, force: true });
    }
  });
  try {
    const discovery = JSON.parse(
      await readFile(join(home, "daemon.json"), "utf8"),
    );
    const pid = s.manager.register({
      schemaVersion: 1,
      name: "退出码",
      root: join(home, "project"),
      services: [
        {
          id: "ok",
          name: "ok",
          cwd: ".",
          command: [
            process.execPath,
            resolve(import.meta.dirname, "fixtures/service.mjs"),
            "silent",
          ],
        },
        { id: "locked", name: "locked", cwd: ".", command: ["/usr/bin/true"] },
        { id: "bad", name: "bad", cwd: ".", command: ["/usr/bin/false"] },
      ],
    }).project.id;
    const url = `http://127.0.0.1:${s.httpPort}/api/v1/projects/${pid}`;
    const headers = {
      Authorization: `Bearer ${discovery.token}`,
      "X-DevPanel-Client": "cli",
      "Content-Type": "application/json",
    };
    assert.equal(
      (
        await fetch(url + "/policy", {
          method: "PUT",
          headers,
          body: JSON.stringify(defaults),
        })
      ).status,
      403,
    );
    assert.equal(
      (await fetch(url + "/services/ok/hold", { method: "DELETE", headers }))
        .status,
      403,
    );
    s.manager.setPolicy(pid, { ...defaults, lockedServices: ["locked"] }, ui);
    const exec = promisify(execFile),
      cli = resolve(import.meta.dirname, "../../cli/src/main.ts");
    const run = async (...args: string[]) => {
      try {
        const r = await exec(process.execPath, [cli, ...args, "--json"], {
          env: { ...process.env, DEVPANEL_HOME: home },
        });
        return { ...r, code: 0 };
      } catch (e: any) {
        return e;
      }
    };
    assert.deepEqual(
      JSON.parse((await run("policy", pid)).stdout).lockedServices,
      ["locked"],
    );
    assert.equal(
      (await run("start", pid, "--service", "ok", "--service", "locked")).code,
      12,
    );
    assert.equal(
      (
        await run(
          "start",
          pid,
          "--service",
          "ok",
          "--service",
          "locked",
          "--service",
          "bad",
        )
      ).code,
      6,
    );
  } finally {
    await cleanup();
  }
});
