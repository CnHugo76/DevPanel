import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, realpath, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { api } from "../src/client.ts";
import { launchAgentOptions, installLaunchAgent, uninstallLaunchAgent } from "../src/launch-agent.ts";
const exec = promisify(execFile);

test("real launchd loads an isolated daemon, leaves registered services idle and unloads cleanly", { skip: process.platform !== "darwin" }, async (t) => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "devpanel-launchd-")));
  const home = join(root, "data");
  const oldHome = process.env.DEVPANEL_HOME;
  process.env.DEVPANEL_HOME = home;
  const label = "io.devpanel.daemon." + createHash("sha256").update(home).digest("hex").slice(0, 16);
  const target = `gui/${process.getuid!()}/${label}`;
  t.after(async () => {
    // This exact job label and all its data were created only for this test.
    await api("/daemon/shutdown", "POST", { stopServices: true }).catch(() => {});
    await exec("/bin/launchctl", ["bootout", target]).catch(() => {});
    if (oldHome === undefined) delete process.env.DEVPANEL_HOME;
    else process.env.DEVPANEL_HOME = oldHome;
    await rm(root, { recursive: true, force: true });
  });
  const o = { ...launchAgentOptions(), userHome: join(root, "fake-user"), env: { ...process.env, DEVPANEL_PORT: "0" } };
  const result = await installLaunchAgent(o);
  assert.equal(result.label, label);
  assert.ok(await stat(result.plistPath));
  const info = await api<any>("/daemon");
  assert.equal(info.home, home);
  const registered = await api<any>("/projects", "POST", {
    schemaVersion: 1, name: "launchd fixture", root,
    services: [{ id: "fixture", name: "fixture", cwd: ".", command: [process.execPath, "-e", "setInterval(()=>{},1000)"] }],
  });
  assert.equal((await api<any>(`/projects/${registered.project.id}/view`)).services[0].state, "idle");
  await uninstallLaunchAgent(false, o);
  await assert.rejects(stat(result.plistPath), { code: "ENOENT" });
  // Loading again must preserve registration without starting any project command.
  await installLaunchAgent(o);
  const view = await api<any>(`/projects/${registered.project.id}/view`);
  assert.equal(view.services[0].state, "idle");
  assert.equal(view.services[0].lastRun, null);
  await uninstallLaunchAgent(false, o);
  await assert.rejects(api("/daemon"));
  await assert.rejects(exec("/bin/launchctl", ["print", target]));
});
