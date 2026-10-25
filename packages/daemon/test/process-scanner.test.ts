import { test, type TestContext } from "node:test";
import { mkdtemp, writeFile, readFile, rm, stat } from "node:fs/promises";
import { daemonLog } from "../src/daemon-log.ts";
import assert from "node:assert/strict";
import { ProcessScanner } from "../src/process-scanner.ts";
import { scanProcesses, resourceSample, type ProcessRow } from "../src/processes.ts";

const mac = { skip: process.platform !== "darwin" };

async function controlledHelper(t: TestContext) {
  const dir = await mkdtemp("/tmp/devpanel-sampler-");
  t.after(() => rm(dir, { recursive: true, force: true }));
  const helper = dir + "/helper", modePath = dir + "/mode", startsPath = dir + "/starts";
  await writeFile(modePath, "ok");
  await writeFile(helper, `#!${process.execPath}
const fs = require('node:fs');
fs.appendFileSync(${JSON.stringify(startsPath)}, 'start\\n');
require('node:readline').createInterface({ input: process.stdin }).on('line', command => {
  const mode = fs.readFileSync(${JSON.stringify(modePath)}, 'utf8');
  if (mode === 'timeout') return;
  if (mode === 'exit') process.exit(7);
  if (mode === 'json') { console.log('invalid SECRET_HELPER_OUTPUT'); return; }
  if (mode === 'schema') { console.log('[[]]'); return; }
  const reply = () => {
    const data = command === 'S' ? [[process.ppid, 0, 0, 1, 'native-fixture']]
      : command === 'O' ? [[process.ppid, 1, 100, 10, 200], [process.pid, 1, 100, 10, 200]]
      : command.slice(2).split(' ').map(pair => {
        const [pid, start] = pair.split(':').map(Number);
        return command.startsWith('R ') ? [pid, start, 100, 10, 200] : [pid, start, []];
      });
    console.log(JSON.stringify(data));
  };
  if (mode === 'slow') setTimeout(reply, 500);
  else reply();
}).on('close', () => process.exit(0));
`, { mode: 0o755 });
  return { dir, helper,
    mode: (mode: string) => writeFile(modePath, mode),
    starts: async () => (await readFile(startsPath, 'utf8').catch(() => '')).split('\n').length - 1,
  };
}

test("500ms helper responses stay native, including concurrent requests", mac, async (t) => {
  const fixture = await controlledHelper(t);
  await fixture.mode("slow");
  const logs: string[] = [];
  const scanner = new ProcessScanner(fixture.helper, { log: line => logs.push(line) });
  t.after(() => scanner.close());
  await scanner.prepare();
  const self = (await scanner.scan()).get(process.pid)!;
  assert.equal(self.command, "native-fixture");
  const pid = scanner.helperPid;
  const first = scanner.scan();
  await new Promise(r => setTimeout(r, 50));
  const second = scanner.scan();
  for (const rows of await Promise.all([first, second])) {
    assert.equal(rows.get(process.pid)!.command, "native-fixture");
    assert.equal(rows.get(process.pid)!.rss, null, "must not use ps");
  }
  assert.ok(await scanner.toolResources());
  assert.equal((await scanner.resources([self]))[0]!.footprint, 200);
  assert.deepEqual((await scanner.listening([self]))?.get(self.pid), []);
  assert.equal(scanner.helperPid, pid);
  assert.deepEqual(logs, []);
});

test("native sampler reuses one helper and agrees with ps identities and CPU accounting", mac, async (t) => {
  const scanner = new ProcessScanner();
  t.after(() => scanner.close());
  await scanner.prepare();
  const native = await scanner.scan(), reference = await scanProcesses();
  const pid = scanner.helperPid;
  assert.ok(pid);
  const self = native.get(process.pid)!;
  assert.equal(self.startedAt, reference.get(process.pid)!.startedAt);
  assert.equal(self.ppid, reference.get(process.pid)!.ppid);
  assert.equal(self.pgid, reference.get(process.pid)!.pgid);
  await scanner.scan();
  assert.equal(scanner.helperPid, pid, "polling must not spawn another process");
  const before = (await scanner.resources([self]))[0]!;
  const cpuBefore = process.cpuUsage();
  const until = performance.now() + 150;
  while (performance.now() < until) Math.sqrt(Math.random());
  const after = (await scanner.resources([self]))[0]!;
  const cpu = process.cpuUsage(cpuBefore);
  assert.ok(after.rss! > 0 && after.footprint! > 0);
  assert.ok(Math.abs((after.cpuMs! - before.cpuMs!) - (cpu.user + cpu.system) / 1000) < 40,
    "Mach ticks must be converted to milliseconds (including Apple silicon timebase)");
  assert.equal(scanner.intervalMs, 250);
});

test("identity mismatch is never attributed memory, and helper closes on EOF", mac, async () => {
  const scanner = new ProcessScanner();
  try {
    await scanner.prepare();
    const self = (await scanner.scan()).get(process.pid)!;
    const sample = (await scanner.resources([{ ...self, startedAt: new Date(Date.parse(self.startedAt) - 1000).toISOString() }]))[0]!;
    assert.equal(sample.rss, null);
    assert.equal(sample.footprint, null);
    const output = resourceSample([sample], new Map(), Date.now());
    assert.equal(output.status, "unavailable");
    assert.equal(output.rssBytes, null);
    assert.equal(output.footprintBytes, null);
    const pid = scanner.helperPid!;
    scanner.close();
    for (let i = 0; i < 50 && (await scanProcesses()).has(pid); i++)
      await new Promise(r => setTimeout(r, 20));
    assert.equal((await scanProcesses()).has(pid), false);
    await assert.rejects(scanner.scan());
  } finally { scanner.close(); }
});

test("only three consecutive spawn failures enable ps fallback", mac, async (t) => {
  let now = 0;
  const logs: string[] = [];
  const scanner = new ProcessScanner("/nonexistent/devpanel-process-sampler", { now: () => now, log: line => logs.push(line) });
  t.after(() => scanner.close());
  await scanner.prepare();
  await assert.rejects(scanner.scan());
  assert.equal(scanner.recovering, true);
  now = 2000;
  await assert.rejects(scanner.scan());
  now = 6000;
  const rows = await scanner.scan();
  assert.ok(rows.get(process.pid)!.rss! > 0);
  assert.equal(scanner.helperPid, null);
  assert.equal(scanner.recovering, false);
  const output = resourceSample([rows.get(process.pid)!], new Map(), Date.now());
  assert.equal(output.footprintBytes, null);
  assert.ok(output.rssBytes! > 0);
  assert.equal(JSON.parse(logs[0]!).reason, "io");
  assert.equal(JSON.parse(logs[1]!).event, "unavailable");
});

test("footprint sums every managed process and never publishes a misleading partial sum", () => {
  const row: ProcessRow = { pid: 1, ppid: 0, pgid: 1, startedAt: "2026-10-20T00:00:00Z", command: "fixture", cpuMs: 50, rss: 100, footprint: 1000 };
  const second = { ...row, pid: 2, rss: 200, footprint: 2000 };
  const complete = resourceSample([row, second], new Map(), Date.now());
  assert.equal(complete.rssBytes, 300);
  assert.equal(complete.footprintBytes, 3000);
  const partial = resourceSample([row, { ...second, rss: null, cpuMs: null, footprint: null }], new Map(), Date.now());
  assert.equal(partial.status, "partial");
  assert.equal(partial.rssBytes, 100);
  assert.equal(partial.footprintBytes, null);
  assert.equal(partial.processCount, 2);
  assert.equal(partial.cpuPercent, null);
  assert.match(partial.note!, /footprint/);
});

test("tool resources contain exactly owner and helper, even with no process discovery", mac, async (t) => {
  const scanner = new ProcessScanner();
  t.after(() => scanner.close());
  await scanner.prepare();
  const rows = await scanner.toolResources();
  assert.ok(rows);
  assert.deepEqual(rows.map(p => p.pid).sort(), [process.pid, scanner.helperPid].sort());
  assert.ok(rows.every(p => p.footprint! > 0 && p.cpuMs! >= 0));
  const broken = new ProcessScanner("/nonexistent/devpanel-sampler");
  t.after(() => broken.close());
  assert.equal(await broken.toolResources(), null);
});

test("native LISTEN collection verifies identity and tracks IPv4/IPv6 sockets closing", mac, async (t) => {
  const { createServer } = await import("node:net");
  const scanner = new ProcessScanner();
  t.after(() => scanner.close());
  await scanner.prepare();
  const self = (await scanner.scan()).get(process.pid)!;
  for (const [host, family] of [["127.0.0.1", "ipv4"], ["::1", "ipv6"]] as const) {
    const server = createServer();
    t.after(() => { if (server.listening) server.close(); });
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(0, host, resolve); });
    const port = (server.address() as import("node:net").AddressInfo).port;
    const result = await scanner.listening([self]);
    assert.ok(result?.get(self.pid)?.some(p => p.port === port && p.address === host && p.family === family && p.scope === "loopback"));
    assert.ok(scanner.helperPid, "native path must not fall back to lsof");
    const wrong = await scanner.listening([{ ...self, startedAt: "1970-01-01T00:00:00.000Z" }]);
    assert.equal(wrong?.has(self.pid), false);
    await new Promise<void>((resolve, reject) => server.close(e => e ? reject(e) : resolve()));
    assert.equal((await scanner.listening([self]))?.get(self.pid)?.some(p => p.port === port), false);
  }
});

test("consecutive timeouts back off to 30s, rate-limit persisted logs and recover", mac, async (t) => {
  const fixture = await controlledHelper(t);
  await fixture.mode("timeout");
  let now = 0;
  const scanner = new ProcessScanner(fixture.helper, { now: () => now, timeoutMs: 1000,
    log: line => daemonLog(fixture.dir, line) });
  t.after(() => scanner.close());
  await scanner.prepare();
  const delays = [2000, 4000, 8000, 16000, 30000, 30000];
  for (const [index, delay] of delays.entries()) {
    if (index < 2) await assert.rejects(scanner.scan(), /采样器不可用/);
    else assert.ok((await scanner.scan()).get(process.pid)!.rss! > 0);
    assert.equal(scanner.recovering, index < 2);
    assert.equal(await fixture.starts(), index + 1);
    assert.equal(scanner.helperPid, null);
    now += delay - 1;
    assert.equal(await scanner.toolResources(), null);
    // Polling any public entry point during backoff must not count another failure or extend it.
    if (index < 2) {
      await assert.rejects(scanner.scan());
      const self = (await scanProcesses()).get(process.pid)!;
      assert.equal((await scanner.resources([self]))[0]!.rss, null);
      assert.equal(await scanner.listening([self]), null);
    } else assert.ok((await scanner.scan()).get(process.pid)!.rss! > 0);
    assert.equal(await fixture.starts(), index + 1);
    now++;
  }
  await fixture.mode("ok");
  assert.equal((await scanner.scan()).get(process.pid)!.command, "native-fixture");
  assert.ok(scanner.helperPid);
  assert.equal(scanner.recovering, false);
  const logs = (await readFile(fixture.dir + "/daemon.log", "utf8")).trim().split("\n").map(line => JSON.parse(line));
  assert.deepEqual(logs.filter(l => l.event === "failure").map(l => [l.reason, l.count, l.suppressed, l.retryMs]),
    [["timeout", 1, 0, 2000], ["timeout", 5, 3, 30000], ["timeout", 6, 0, 30000]]);
  assert.equal(logs.find(l => l.event === "unavailable").consecutiveFailures, 3);
  assert.equal(logs.at(-1).event, "recovered");
  assert.equal(logs.at(-1).consecutiveFailures, 6);
  assert.equal(logs.at(-1).time, new Date(now).toISOString());
  assert.equal((await stat(fixture.dir + "/daemon.log")).mode & 0o777, 0o600);
  // A new failure after recovery starts at the short delay again.
  await fixture.mode("timeout");
  await assert.rejects(scanner.scan());
  now += 1999;
  assert.equal(await scanner.toolResources(), null);
  await fixture.mode("ok");
  now++;
  assert.ok(await scanner.toolResources());
});

for (const mode of ["exit", "json", "schema"] as const) {
  test(`${mode} failures are classified, counted once and only valid output recovers`, mac, async (t) => {
    const fixture = await controlledHelper(t);
    let now = 0;
    const logs: Record<string, any>[] = [];
    const scanner = new ProcessScanner(fixture.helper, { now: () => now, log: line => logs.push(JSON.parse(line)) });
    t.after(() => scanner.close());
    await scanner.prepare();
    await scanner.scan();
    await fixture.mode(mode);
    // Queued callers and public catches must not count the same transport failure more than once.
    const results = await Promise.allSettled([scanner.scan(), scanner.scan(), scanner.scan()]);
    assert.ok(results.every(r => r.status === "rejected"));
    assert.equal(logs.length, 1);
    assert.equal(logs[0]!.reason, mode === "exit" ? "exit" : "invalid-output");
    assert.equal(logs[0]!.consecutiveFailures, 1);
    if (mode === "exit") assert.equal(logs[0]!.exitCode, 7);
    now = 2000;
    await assert.rejects(scanner.scan());
    now = 6000;
    assert.ok((await scanner.scan()).get(process.pid)!.rss! > 0);
    assert.equal(logs.find(l => l.event === "unavailable")!.consecutiveFailures, 3);
    assert.ok(!logs.some(l => l.event === "recovered"), "invalid schemas must not reset failures");
    now = 14000;
    await fixture.mode("ok");
    assert.ok(await scanner.toolResources());
    assert.equal(logs.at(-1)!.event, "recovered");
    assert.equal(logs.at(-1)!.consecutiveFailures, 3);
    assert.ok(!JSON.stringify(logs).includes("SECRET_HELPER_OUTPUT"));
    const count = logs.length;
    scanner.close();
    assert.equal(logs.length, count, "intentional shutdown is not a failure");
  });
}

test("one timeout marks daemon tool samples partial without refreshing their timestamp", mac, async (t) => {
  const { Manager } = await import("../src/manager.ts");
  const fixture = await controlledHelper(t);
  let now = 0;
  const scanner = new ProcessScanner(fixture.helper, { now: () => now, timeoutMs: 1000,
    log: line => daemonLog(fixture.dir, line) });
  const manager = new Manager(fixture.dir, 0);
  t.after(() => manager.close());
  const internal = manager as unknown as { scanner: ProcessScanner; selfSampling: Promise<void> | null; selfTimer: NodeJS.Timeout; refreshSelf(): Promise<void> };
  clearInterval(internal.selfTimer);
  await internal.selfSampling;
  internal.scanner.close();
  internal.scanner = scanner;
  await scanner.prepare();
  await internal.refreshSelf();
  const before = manager.info().toolResources!;
  assert.ok(before.total.footprintBytes! > 0);
  await fixture.mode("timeout");
  await internal.refreshSelf();
  const partial = manager.info().toolResources!;
  assert.equal(partial.helpers.status, "partial");
  assert.equal(partial.total.status, "partial");
  assert.equal(partial.total.sampledAt, before.total.sampledAt);
  assert.equal(partial.total.cpuPercent, null);
  assert.equal(partial.total.footprintBytes, null);
  assert.match(partial.helpers.note!, /等待重试/);
  now = 2000;
  await internal.refreshSelf();
  assert.equal(manager.info().toolResources!.helpers.status, "partial");
  now = 6000;
  await internal.refreshSelf();
  assert.equal(manager.info().toolResources!.helpers.status, "unavailable");
  now = 14000;
  await fixture.mode("ok");
  await internal.refreshSelf();
  assert.equal(manager.info().toolResources!.total.status, "sampling");
  await internal.refreshSelf();
  assert.equal(manager.info().toolResources!.total.status, "ok");
  assert.match(await readFile(fixture.dir + "/daemon.log", "utf8"), /"event":"recovered"/);
});


test("pending compilation never blocks discovery and a failed build can retry", mac, async (t) => {
  const { nativeSamplerPath, prepareNativeSampler } = await import("../src/native-build.ts");
  await prepareNativeSampler();
  let complete!: (path: string) => void;
  const scanner = new ProcessScanner(undefined, { build: () => new Promise(resolve => { complete = resolve; }) });
  t.after(() => scanner.close());
  const warmup = scanner.prepare();
  const rows = await scanner.scan(); // Deliberately resolve compilation only AFTER discovery.
  assert.ok(rows.get(process.pid)!.rss! > 0);
  assert.equal(scanner.helperPid, null);
  assert.equal(scanner.intervalMs, 250);
  complete(nativeSamplerPath);
  await warmup;
  await scanner.scan();
  assert.ok(scanner.helperPid);

  let now = 0, attempts = 0;
  const retry = new ProcessScanner(undefined, { now: () => now, build: async () => {
    if (++attempts === 1) throw new Error("compiler unavailable");
    return nativeSamplerPath;
  } });
  t.after(() => retry.close());
  await retry.prepare();
  await retry.scan();
  assert.equal(attempts, 1);
  now = 1999;
  await retry.prepare();
  assert.equal(attempts, 1);
  now = 2000;
  await retry.prepare();
  await retry.scan();
  assert.equal(attempts, 2);
  assert.ok(retry.helperPid);
});
