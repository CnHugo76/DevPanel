import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
const exec = promisify(execFile);

test("both package runners report the hung test and exit despite a live timer", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "devpanel-runner-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const fixture = join(home, "hang.test.mjs");
  await writeFile(fixture, `import { test } from 'node:test';
test('intentional hanging fixture', async () => {
  setInterval(() => {}, 1000);
  await new Promise(() => {});
});
`);
  const env = { ...process.env, DEVPANEL_HOME: home };
  // A fresh runner must not inherit the parent test worker marker.
  delete env.NODE_TEST_CONTEXT;
  for (const name of ["cli", "daemon"]) {
    const pkg = JSON.parse(await readFile(new URL(`../../${name}/package.json`, import.meta.url), "utf8"));
    // Use the real runner flags; shorten only the deadline to keep this regression fast.
    const args = pkg.scripts.test.split(" ").slice(1, -1).map((arg: string) =>
      arg.startsWith("--test-timeout=") ? "--test-timeout=200" : arg.endsWith(".ts") ? new URL(`../../${name}/${arg}`, import.meta.url).pathname : arg);
    await assert.rejects(exec(process.execPath, [...args, fixture], {
      env, timeout: 20000,
    }), (e: any) => {
      assert.equal(e.killed, false, `${name} runner needed an external kill`);
      assert.equal(e.code, 1);
      assert.match(e.stdout + e.stderr, /intentional hanging fixture/);
      assert.match(e.stdout + e.stderr, /test timed out after 200ms/);
      return true;
    });
  }
});


test("daemon runner reports and safely cleans a fixture left alive by its test", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "dp-leak-audit-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const fixture = join(home, "leak.test.mjs");
  const managerURL = new URL("../../daemon/src/manager.ts", import.meta.url).href;
  const storageURL = new URL("../../daemon/src/storage.ts", import.meta.url).href;
  await writeFile(fixture, `import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Manager } from ${JSON.stringify(managerURL)};
import { limits, sleep } from ${JSON.stringify(storageURL)};
test('intentional leaked fixture', async t => {
  const manager = new Manager(process.env.DEVPANEL_HOME, 1, { ...limits, startGraceMs: 50 });
  t.after(() => manager.close());
  const project = manager.register({ schemaVersion: 1, name: 'leak', root: process.env.DEVPANEL_HOME, services: [{ id: 'leak', name: 'leak', cwd: '.', command: [process.execPath, '-e', 'setInterval(()=>{},1000)'] }] }).project;
  const op = manager.submit({ projectId: project.id, action: 'start' });
  const deadline = Date.now() + 5000;
  while (['queued','running'].includes(op.state) && Date.now() < deadline) await sleep(10);
  assert.equal(op.state, 'succeeded');
});
`);
  const env = { ...process.env, DEVPANEL_HOME: home };
  delete env.NODE_TEST_CONTEXT;
  const runner = new URL("../../daemon/test/run-tests.ts", import.meta.url).pathname;
  await assert.rejects(exec(process.execPath, [runner, "--test-timeout=10000", "--test-force-exit", fixture], { env, timeout: 30000 }), (error: any) => {
    assert.equal(error.killed, false);
    assert.equal(error.code, 1);
    assert.match(error.stdout, /intentional leaked fixture/);
    assert.match(error.stderr, /all recorded fixture identities must exit/);
    return true;
  });
});
