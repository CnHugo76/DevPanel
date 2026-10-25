import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import type { ProcessInfo } from "@devpanel/contract";
import { Git } from "../src/git.ts";
import { scanProcesses, verifiedSignal } from "../src/processes.ts";
import { sleep } from "../src/storage.ts";

test("Git timeout tracks a short-lived parent's detached child and leaves no survivors", { timeout: 120000 }, async t => {
  const home = await mkdtemp("/tmp/dp-git-timeout-");
  const observedFile = join(home, "observed");
  const identitiesFile = join(home, "identities.json");
  let owned: ProcessInfo[] = [];
  let query: Promise<unknown> | undefined;
  let queryFailure: unknown;
  const readIdentities = async () => {
    try {
      const captured = JSON.parse(await readFile(identitiesFile, "utf8")) as ProcessInfo[];
      if (captured.length) owned = captured;
    } catch { /* The fixture may not have published its identity handshake yet. */ }
  };
  // Register before spawn/assertions. The fixture independently records real ps
  // identities so even the pre-fix red test can safely remove its detached child.
  t.after(async () => {
    await readIdentities();
    try {
      verifiedSignal(owned, await scanProcesses(), "SIGKILL");
      await query?.catch(() => {});
      let remaining: ProcessInfo[] = [];
      for (let i = 0; i < 100; i++) {
        const rows = await scanProcesses();
        remaining = owned.filter(p => rows.get(p.pid)?.startedAt === p.startedAt);
        if (!remaining.length) break;
        await sleep(20);
      }
      assert.deepEqual(remaining, [], "independent fixture cleanup must leave no process");
    } finally { await rm(home, { recursive: true, force: true }); }
  });
  const fixtureScript = join(home, "fixture.mjs");
  await writeFile(fixtureScript, `
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
const capture = (pid, ppid) => {
  const time = execFileSync('/bin/ps', ['-p', String(pid), '-o', 'lstart='], {
    encoding: 'utf8', timeout: 5000, env: { ...process.env, LC_ALL: 'C', TZ: 'UTC' }
  }).trim();
  return { pid, ppid, startedAt: new Date(Date.parse(time + ' UTC')).toISOString(), command: 'node' };
};
const identities = [capture(process.pid, process.ppid)];
const publish = () => fs.writeFileSync(${JSON.stringify(identitiesFile)}, JSON.stringify(identities));
publish();
setTimeout(() => {
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { detached: true, stdio: 'inherit' });
  identities.push(capture(child.pid, process.pid));
  publish();
  const wait = setInterval(() => { if (fs.existsSync(${JSON.stringify(observedFile)})) { clearInterval(wait); process.exit(0); } }, 10);
}, 100);
`, { mode: 0o600 });
  const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
  await writeFile(join(home, "git"), `#!/bin/sh
exec ${quote(process.execPath)} ${quote(fixtureScript)} "$@"
`, { mode: 0o755 });
  query = new Git({ PATH: home }, async () => {
    const rows = await scanProcesses();
    await readIdentities();
    if (owned.length === 2 && owned.every(p => rows.get(p.pid)?.startedAt === p.startedAt)) await writeFile(observedFile, "observed");
    return rows;
  }).status(home);
  void query.catch(error => { queryFailure = error; }); // Keep setup failures observable without an unhandled rejection.
  // Wait for the identity handshake before asserting process behavior. Leave
  // time for the parent to exit before the unchanged 10-second query deadline.
  const setupDeadline = Date.now() + 8000;
  while (Date.now() < setupDeadline) {
    await readIdentities();
    if (owned.length === 2) break;
    await sleep(10);
  }
  assert.equal(owned.length, 2, `fixture records parent and detached child before the parent exits: ${JSON.stringify(queryFailure)}`);
  const parent = owned[0]!, child = owned[1]!;
  assert.equal(child.ppid, parent.pid);
  await sleep(500);
  const before = await scanProcesses();
  assert.notEqual(before.get(parent.pid)?.startedAt, parent.startedAt, "parent has already exited");
  assert.equal(before.get(child.pid)?.startedAt, child.startedAt, "detached child still holds the query pipes");
  await assert.rejects(query, (e: unknown) => {
    const error = e as { error?: { code: string; details?: { stderr?: string } } };
    return error.error?.code === "GIT_FAILED" && !!error.error.details?.stderr?.includes("超时");
  });
  const after = await scanProcesses();
  assert.ok(owned.every(p => after.get(p.pid)?.startedAt !== p.startedAt), "timeout must finish only after all verified fixture processes exit");
});
