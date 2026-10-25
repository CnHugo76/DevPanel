import { test } from "node:test";
import assert from "node:assert/strict";
import { Engine, DEFAULT_LIMITS } from "../src/engine.ts";
import { addVirtualDir } from "../src/validate.ts";
import type { Operation } from "@devpanel/contract";
const ui = { client: "ui" as const, agent: null },
  actor = { client: "cli" as const, agent: "codex" };
test("mock 托管规则拒绝、暂停解除、强停权限和敏感动态与真实 daemon 一致", async () => {
  addVirtualDir("/virtual/policy");
  const e = new Engine("/tmp/dp-mock-policy", {
    ...DEFAULT_LIMITS,
    startGraceMs: 20,
  });
  const config = {
    schemaVersion: 1 as const,
    name: "mock-policy",
    root: "/virtual/policy",
    env: { TOKEN: { secret: true as const, value: "mock-policy-secret-042" } },
    services: [
      {
        id: "web",
        name: "web",
        cwd: ".",
        command: ["node", "server.js"],
        stopTimeoutSec: 3,
      },
    ],
  };
  const pid = e.register(config).body.project.id;
  const finish = (op: Operation) => e.waitOperation(op.id, 10000);
  const action = (
    action: string,
    client: "cli" | "ui" = "cli",
    overrideHold = false,
  ) =>
    finish(
      e.submit(
        { projectId: pid, action, overrideHold },
        client === "ui" ? ui : actor,
      ),
    );
  try {
    await action("start");
    await action("stop", "ui");
    assert.ok(e.view(e.getProj(pid)).services[0]!.hold);
    const history = e.runsOf(pid, "web").length;
    assert.equal(
      (await action("start")).results[0]!.error!.details!.reason,
      "hold",
    );
    assert.equal(e.runsOf(pid, "web").length, history);
    await action("start", "cli", true);
    assert.equal(e.view(e.getProj(pid)).services[0]!.hold, null);
    assert.ok(
      e.activity.entries.some(
        (x) => x.detail.kind === "operation" && x.detail.overrideHold,
      ),
    );
    e.setPolicy(
      pid,
      {
        holdAfterUserStop: true,
        agentForceStop: "deny",
        lockedServices: ["web"],
      },
      ui,
    );
    const activityCount = e.activity.entries.length;
    assert.throws(
      () => e.remove(pid),
      (err: any) => err.status === 409,
    );
    assert.deepEqual(e.getPolicy(pid).lockedServices, ["web"]);
    assert.equal(e.activity.entries.length, activityCount);
    for (const cmd of ["start", "stop", "restart", "force-stop"])
      assert.equal(
        (await action(cmd)).results[0]!.error!.details!.reason,
        "locked",
      );
    await action("stop", "ui");
    e.setPolicy(
      pid,
      { holdAfterUserStop: false, agentForceStop: "allow", lockedServices: [] },
      ui,
    );
    assert.equal(e.view(e.getProj(pid)).services[0]!.hold, null);
    await action("start");
    assert.equal((await action("force-stop")).state, "succeeded");
    assert.equal(
      JSON.stringify(e.activity.entries).includes("mock-policy-secret-042"),
      false,
    );
    assert.throws(
      () => e.setPolicy(pid, {}, actor),
      (err: any) => err.status === 403,
    );
  } finally {
    e.stop();
  }
});
test("mock 删除服务时清理暂停与锁，并保留配置发起方的动态", async () => {
  addVirtualDir("/virtual/policy-prune");
  const e = new Engine("/tmp/dp-mock-policy-prune", {
    ...DEFAULT_LIMITS,
    startGraceMs: 10,
  });
  const config = {
    schemaVersion: 1 as const,
    name: "prune",
    root: "/virtual/policy-prune",
    services: ["a", "b"].map((id) => ({
      id,
      name: id,
      cwd: ".",
      command: ["node", "server.js"],
    })),
  };
  const p = e.register(config).body.project;
  try {
    await e.waitOperation(
      e.submit({ projectId: p.id, serviceIds: ["a"], action: "start" }, ui).id,
      10000,
    );
    await e.waitOperation(
      e.submit({ projectId: p.id, serviceIds: ["a"], action: "stop" }, ui).id,
      10000,
    );
    e.setPolicy(
      p.id,
      {
        holdAfterUserStop: true,
        agentForceStop: "deny",
        lockedServices: ["a"],
      },
      ui,
    );
    const count = e.activity.entries.length;
    e.update(
      p.id,
      {
        ifRevision: p.revision,
        config: { ...config, services: [config.services[1]] },
      },
      actor,
    );
    assert.deepEqual(e.getPolicy(p.id).lockedServices, []);
    const entries = e.activity.entries
      .slice(count)
      .filter((x) => x.detail.kind === "policy");
    assert.deepEqual(
      entries.map((x) => x.detail.kind === "policy" && x.detail.change).sort(),
      ["release", "unlock"],
    );
    assert.ok(entries.every((x) => x.actor.agent === "codex"));
  } finally {
    e.stop();
  }
});

for (const client of ["ui", "cli"] as const)
  test(`mock ${client} shutdown 保留暂停锁定且动态记录请求方`, async (t) => {
    const { createMockServer } = await import("../src/server.ts");
    addVirtualDir("/virtual/shutdown-" + client);
    const e = new Engine("/tmp/dp-mock-shutdown-" + client, {
      ...DEFAULT_LIMITS,
      startGraceMs: 10,
    });
    const { server } = createMockServer({
      engine: e,
      port: 0,
      token: "test-token",
      uiDir: null,
      log: () => {},
    });
    t.after(async () => {
      e.stop();
      await new Promise<void>((done) => server.close(() => done()));
    });
    await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
    const p = e.register({
      schemaVersion: 1,
      name: "shutdown",
      root: "/virtual/shutdown-" + client,
      services: ["held", "live"].map((id) => ({
        id,
        name: id,
        cwd: ".",
        command: ["node", "server.js"],
      })),
    }).body.project;
    await e.waitOperation(
      e.submit({ projectId: p.id, action: "start" }, ui).id,
      10000,
    );
    await e.waitOperation(
      e.submit({ projectId: p.id, action: "stop", serviceIds: ["held"] }, ui)
        .id,
      10000,
    );
    const hold = e.view(e.getProj(p.id)).services[0]!.hold;
    e.setPolicy(
      p.id,
      {
        holdAfterUserStop: true,
        agentForceStop: "deny",
        lockedServices: ["live"],
      },
      ui,
    );
    const before = e.activity.entries.length;
    const port = (server.address() as import("node:net").AddressInfo).port;
    const response = await fetch(
      `http://127.0.0.1:${port}/api/v1/daemon/shutdown`,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer test-token",
          "Content-Type": "application/json",
          "X-DevPanel-Client": client,
        },
        body: JSON.stringify({ stopServices: true }),
        signal: AbortSignal.timeout(10000),
      },
    );
    assert.equal(((await response.json()) as Operation).state, "succeeded");
    const services = e.view(e.getProj(p.id)).services;
    assert.deepEqual(services[0]!.hold, hold);
    assert.equal(services[1]!.hold, null);
    assert.ok(services.every((s) => s.currentRun === null));
    assert.deepEqual(e.getPolicy(p.id).lockedServices, ["live"]);
    assert.deepEqual(
      e.activity.entries
        .slice(before)
        .map((a) => [a.actor.client, a.detail.kind]),
      [[client, "operation"]],
    );
  });
