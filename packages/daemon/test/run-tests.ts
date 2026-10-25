import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ProcessInfo } from "@devpanel/contract";
import { scanProcesses } from "../src/processes.ts";
import { stopFixtureProcesses } from "./helpers/cleanup.ts";

const ledger = await mkdtemp(join(tmpdir(), "dp-test-ledger-"));
try {
  const args = process.argv.slice(2);
  const child = spawn(
    process.execPath,
    [
      "--import",
      join(import.meta.dirname, "helpers/fixture-audit.ts"),
      "--test",
      ...args,
    ],
    {
      stdio: "inherit",
      env: { ...process.env, DEVPANEL_TEST_PROCESS_LEDGER: ledger },
    },
  );
  const code = await new Promise<number>((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", (code) => resolve(code ?? 1));
  });
  const owned: ProcessInfo[] = [];
  for (const name of await readdir(ledger))
    owned.push(...JSON.parse(await readFile(join(ledger, name), "utf8")));
  const unique = [
    ...new Map(owned.map((p) => [`${p.pid}:${p.startedAt}`, p])).values(),
  ];
  const rows = await scanProcesses();
  const remaining = unique.filter(
    (p) => rows.get(p.pid)?.startedAt === p.startedAt,
  );
  // Still clean a failed test's verified fixtures, but never turn that failure green.
  if (remaining.length) await stopFixtureProcesses(remaining);
  assert.deepEqual(
    remaining,
    [],
    "all recorded fixture identities must exit before the full suite finishes",
  );
  console.log(
    `Fixture process audit: ${unique.length} identities, 0 remaining`,
  );
  process.exitCode = code;
} finally {
  await rm(ledger, { recursive: true, force: true });
}
