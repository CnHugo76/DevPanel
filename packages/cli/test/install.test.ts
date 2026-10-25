import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { installCli } from "../src/setup-cli.ts";
import { installLaunchAgent, uninstallLaunchAgent, type LaunchAgentOptions } from "../src/launch-agent.ts";
import { api, ClientError } from "../src/client.ts";
const exec = promisify(execFile);
const missingJob = () => Object.assign(new Error("missing job"), { code: 113, stderr: "Could not find service" });
const unreachable = () => new ClientError({ error: { code: "DAEMON_UNREACHABLE", message: "unreachable" } });
async function fixture(t: import("node:test").TestContext) {
  const root = await mkdtemp(join(tmpdir(), "devpanel-install-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const calls: string[][] = [];
  let loaded = false, alive = false;
  const o: LaunchAgentOptions = {
    platform: "darwin", userHome: join(root, "user"), home: join(root, "data & ' < >"), uid: 501,
    node: "/opt/Node & tools/node", daemon: "/repo with spaces/daemon.ts",
    env: { HOME: root, PATH: "/tools/bin:/usr/bin:/bin", PRIVATE_TOKEN: "must-not-leak", DEVPANEL_PORT: "0" },
    launchctl: async (args) => {
      calls.push(args);
      if (args[0] === "print") { if (!loaded) throw missingJob(); return alive ? "\tpid = 123\n" : "state = exited"; }
      if (args[0] === "bootstrap") { loaded = true; alive = true; }
      if (args[0] === "bootout") { loaded = false; alive = false; }
      return "";
    },
    request: (async (path: string) => {
      if (!alive) throw unreachable();
      if (path === "/daemon/shutdown") { alive = false; return {}; }
      assert.equal(path, "/daemon");
      return { pid: 123 };
    }) as typeof api,
  };
  return { root, o, calls, setAlive: (value: boolean) => { alive = value; } };
}

test("CLI shims run from another repository with a minimal PATH and preserve argv", async (t) => {
  const s = await fixture(t), bin = join(s.root, "bin with ' quotes & $dollar");
  // A Node path containing shell metacharacters must remain a single literal argument.
  await mkdir(bin);
  const nodeAlias = join(bin, "node ' $alias");
  await symlink(process.execPath, nodeAlias);
  await installCli(bin, nodeAlias);
  const env = { ...process.env, PATH: bin + ":/usr/bin:/bin", DEVPANEL_HOME: join(s.root, "isolated") };
  const help = await exec("devpanel", ["--help"], { cwd: s.root, env });
  assert.match(help.stdout, /DevPanel/);
  await assert.rejects(exec("devpanel", ["status", "id with spaces", "--json"], { cwd: s.root, env }), (e: any) => {
    assert.equal(e.code, 3);
    assert.equal(JSON.parse(e.stdout).error.code, "DAEMON_UNREACHABLE");
    return true;
  });
  await assert.rejects(exec("devpaneld", [], { cwd: s.root, env: { ...env, DEVPANEL_PORT: "invalid" } }), (e: any) => {
    assert.equal(e.code, 2);
    assert.match(e.stderr, /DEVPANEL_PORT/);
    return true;
  });
  await installCli(bin, nodeAlias);
  assert.equal((await stat(join(bin, "devpanel"))).mode & 0o777, 0o755);
});

test("CLI installation checks both destinations and refuses foreign files or symlinks", async (t) => {
  const { root } = await fixture(t), bin = join(root, "bin");
  await mkdir(bin);
  await writeFile(join(bin, "devpaneld"), "foreign");
  await assert.rejects(installCli(bin), /未覆盖/);
  await assert.rejects(stat(join(bin, "devpanel")), { code: "ENOENT" });
  await rm(join(bin, "devpaneld"));
  await symlink(join(root, "missing"), join(bin, "devpaneld"));
  await assert.rejects(installCli(bin), /未覆盖/);
});

test("LaunchAgent uses literal argv, explicit allowlisted PATH and daemon-only RunAtLoad; install/uninstall are idempotent", async (t) => {
  const { o, calls } = await fixture(t);
  const result = await installLaunchAgent(o);
  const plist = await readFile(result.plistPath, "utf8");
  assert.match(plist, /Node &amp; tools/);
  assert.match(plist, /&apos; &lt; &gt;/);
  assert.match(plist, /<key>PATH<\/key><string>\/tools\/bin:\/usr\/bin:\/bin<\/string>/);
  assert.match(plist, /<key>RunAtLoad<\/key><true\/>/);
  assert.match(plist, /<key>KeepAlive<\/key><false\/>/);
  assert.match(plist, /<key>AbandonProcessGroup<\/key><true\/>/);
  assert.ok(!plist.includes("must-not-leak") && !plist.includes("PRIVATE_TOKEN"));
  assert.equal((await stat(result.plistPath)).mode & 0o777, 0o600);
  if (process.platform === "darwin") await exec("/usr/bin/plutil", ["-lint", result.plistPath]);
  assert.equal((await installLaunchAgent(o)).alreadyInstalled, true);
  assert.equal(calls.filter((x) => x[0] === "bootstrap").length, 1);
  assert.equal((await uninstallLaunchAgent(false, o)).installed, false);
  await assert.rejects(stat(result.plistPath), { code: "ENOENT" });
  await uninstallLaunchAgent(false, o);
  assert.equal(calls.filter((x) => x[0] === "bootout").length, 1);
});

test("existing daemon environment wins over the installing terminal; aliases share one label", async (t) => {
  const { o, root } = await fixture(t);
  await mkdir(o.home, { recursive: true });
  await writeFile(join(o.home, "environment.json"), JSON.stringify({ PATH: "/persisted/tools", SECRET: "hidden" }));
  const result = await installLaunchAgent(o);
  const plist = await readFile(result.plistPath, "utf8");
  assert.match(plist, /<string>\/persisted\/tools<\/string>/);
  assert.ok(!plist.includes("hidden") && !plist.includes("/tools/bin"));
  const alias = join(root, "alias");
  await symlink(o.home, alias);
  assert.equal((await installLaunchAgent({ ...o, home: alias })).label, result.label);
});

test("missing PATH gets system default; bootstrap failure removes new plist and surfaces a safe error", async (t) => {
  const { o } = await fixture(t);
  delete o.env.PATH;
  let path = "";
  o.launchctl = async (args) => {
    if (args[0] === "print") throw missingJob();
    if (args[0] === "bootstrap") {
      path = args[2]!;
      assert.match(await readFile(path, "utf8"), /\/usr\/bin:\/bin:\/usr\/sbin:\/sbin/);
    }
    throw new Error("private launchctl diagnostic");
  };
  await assert.rejects(installLaunchAgent(o), /launchctl bootstrap 失败/);
  await assert.rejects(stat(path), { code: "ENOENT" });
});

test("uninstall preserves job and plist on PROJECT_RUNNING, STOP_TIMEOUT and ownership mismatch", async (t) => {
  const { o, calls } = await fixture(t);
  const installed = await installLaunchAgent(o);
  const request = o.request;
  o.request = (async (path: string) => {
    if (path === "/daemon/shutdown") throw new ClientError({ error: { code: "PROJECT_RUNNING", message: "running" } });
    return request(path);
  }) as typeof api;
  await assert.rejects(uninstallLaunchAgent(false, o), /running/);
  const timeout = { state: "failed", results: [{ outcome: "stop-timeout", error: { code: "STOP_TIMEOUT" } }] };
  o.request = (async (path: string, _method: string, body: any) => {
    if (path === "/daemon/shutdown") { assert.equal(body.stopServices, true); return timeout; }
    return request(path);
  }) as typeof api;
  assert.deepEqual(await uninstallLaunchAgent(true, o), timeout);
  o.request = (async () => ({ pid: 999 })) as typeof api;
  await assert.rejects(uninstallLaunchAgent(false, o), /无法核验/);
  assert.ok(await stat(installed.plistPath));
  assert.equal(calls.filter((x) => x[0] === "bootout").length, 0);
});

test("install refuses a manually started daemon and unsupported platforms without side effects", async (t) => {
  const { o, setAlive, calls } = await fixture(t);
  setAlive(true);
  await assert.rejects(installLaunchAgent(o), /已由其他入口启动/);
  await assert.rejects(installLaunchAgent({ ...o, platform: "linux" }), /仅支持 macOS/);
  assert.equal(calls.filter((x) => x[0] === "bootstrap").length, 0);
  await assert.rejects(stat(o.home), { code: "ENOENT" });
});


test("launchctl query and bootout errors never masquerade as successful uninstall", async (t) => {
  const { o } = await fixture(t);
  const installed = await installLaunchAgent(o);
  const launchctl = o.launchctl;
  o.launchctl = async () => { throw new Error("permission denied"); };
  await assert.rejects(uninstallLaunchAgent(false, o), /无法查询/);
  assert.ok(await stat(installed.plistPath));
  o.launchctl = async (args) => {
    if (args[0] === "bootout") throw new Error("bootout failed");
    return launchctl(args);
  };
  await assert.rejects(uninstallLaunchAgent(false, o), /bootout 失败/);
  assert.ok(await stat(installed.plistPath));
});


test("Homebrew shims and plist retain the opt path across Node upgrades", async (t) => {
  const { o, root } = await fixture(t);
  const prefix = join(root, "homebrew with spaces");
  const oldBin = join(prefix, "Cellar/node@24/24.21.0/bin");
  const newBin = join(prefix, "Cellar/node@24/24.22.0/bin");
  await mkdir(oldBin, { recursive: true });
  await mkdir(newBin, { recursive: true });
  await symlink(process.execPath, join(oldBin, "node"));
  await symlink(process.execPath, join(newBin, "node"));
  await mkdir(join(prefix, "opt"));
  const opt = join(prefix, "opt/node@24");
  await symlink(join(prefix, "Cellar/node@24/24.21.0"), opt);
  const stable = join(opt, "bin/node");
  const bin = join(root, "bin");
  await installCli(bin, join(oldBin, "node"));
  const installed = await installLaunchAgent({ ...o, node: join(oldBin, "node") });
  const plist = await readFile(installed.plistPath, "utf8");
  assert.ok(plist.includes(`<string>${stable}</string>`));
  assert.ok(!plist.includes("Cellar"));
  for (const name of ["devpanel", "devpaneld"]) {
    const shim = await readFile(join(bin, name), "utf8");
    assert.ok(shim.includes(stable));
    assert.ok(!shim.includes("Cellar"));
  }
  // Simulate brew switching opt and deleting the old keg, without regenerating launchers.
  await rm(opt);
  await symlink(join(prefix, "Cellar/node@24/24.22.0"), opt);
  await rm(join(prefix, "Cellar/node@24/24.21.0"), { recursive: true });
  const env = { ...process.env, PATH: "/usr/bin:/bin", DEVPANEL_HOME: o.home };
  assert.match((await exec(join(bin, "devpanel"), ["--help"], { env })).stdout, /DevPanel/);
  // The exact plist executable works even when launchd's PATH cannot find Homebrew Node.
  assert.match((await exec(stable, ["--version"], { env })).stdout, /^v\d+/);
});
