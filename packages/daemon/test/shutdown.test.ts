import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ProcessInfo } from "@devpanel/contract";
import { startServer } from "../src/server.ts";
import { terminal } from "../src/manager.ts";
import { limits, sleep } from "../src/storage.ts";
import { stopFixtureProcesses } from "./helpers/cleanup.ts";

for (const client of ["ui", "cli"] as const)
  test(`${client} shutdown 绕过锁定且不产生暂停，已有暂停保持`, async (t) => {
    const home = await mkdtemp(join(tmpdir(), "dp-shutdown-"));
    await mkdir(join(home, "project"));
    const s = await startServer(home, 0, { ...limits, startGraceMs: 60 });
    const owned: ProcessInfo[] = [];
    s.manager.on("event", () =>
      owned.push(...[...s.manager.runs.values()].flatMap((r) => r.known)),
    );
    t.after(async () => {
      try {
        await stopFixtureProcesses(owned);
      } finally {
        await s.close();
        await rm(home, { recursive: true, force: true });
      }
    });
    const m = s.manager;
    const pid = m.register({
      schemaVersion: 1,
      name: "shutdown",
      root: join(home, "project"),
      services: ["held", "live"].map((id) => ({
        id,
        name: id,
        cwd: ".",
        command: [
          process.execPath,
          resolve(import.meta.dirname, "fixtures/service.mjs"),
          "silent",
        ],
      })),
    }).project.id;
    const ui = { client: "ui" as const, agent: null };
    async function action(action: string, serviceIds?: string[]) {
      const op = m.submit({ projectId: pid, action, serviceIds }, ui);
      const deadline = Date.now() + 5000;
      while (!terminal(op) && Date.now() < deadline) await sleep(10);
      assert.equal(op.state, "succeeded");
    }
    await action("start");
    await action("stop", ["held"]);
    const hold = m.view(pid).services[0]!.hold;
    m.setPolicy(
      pid,
      {
        holdAfterUserStop: true,
        lockedServices: ["live"],
        agentForceStop: "deny",
      },
      ui,
    );
    const before = m.activity.entries.length;
    if (client === "cli") {
      const result = await promisify(execFile)(
        process.execPath,
        [
          resolve(import.meta.dirname, "../../cli/src/main.ts"),
          "daemon",
          "stop",
          "--stop-services",
          "--json",
        ],
        { env: { ...process.env, DEVPANEL_HOME: home }, timeout: 10000 },
      );
      assert.equal(JSON.parse(result.stdout).state, "succeeded");
    } else {
      const discovery = JSON.parse(
        await readFile(join(home, "daemon.json"), "utf8"),
      );
      const response = await fetch(
        `http://127.0.0.1:${s.httpPort}/api/v1/daemon/shutdown`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${discovery.token}`,
            "Content-Type": "application/json",
            "X-DevPanel-Client": "ui",
          },
          body: JSON.stringify({ stopServices: true }),
          signal: AbortSignal.timeout(10000),
        },
      );
      assert.equal(((await response.json()) as any).state, "succeeded");
    }
    const services = m.view(pid).services;
    assert.deepEqual(services[0]!.hold, hold);
    assert.equal(services[1]!.hold, null);
    assert.deepEqual(m.getPolicy(pid).lockedServices, ["live"]);
    assert.ok(services.every((service) => service.currentRun === null));
    assert.deepEqual(
      m.activity.entries
        .slice(before)
        .map((e) => [e.actor.client, e.detail.kind]),
      [[client, "operation"]],
    );
  });
