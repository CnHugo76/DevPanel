import assert from "node:assert/strict";
import { rm } from "node:fs/promises";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ProcessInfo } from "@devpanel/contract";
import type { startServer } from "../../src/server.ts";
import { discover, scanProcesses, verifiedSignal } from "../../src/processes.ts";
import { sleep } from "../../src/storage.ts";

const cleanupIdentities = new Map<string, ProcessInfo>();

/** Fallback signals only identities saved by this run, plus their verified descendants. */
export async function stopFixtureProcesses(owned: ProcessInfo[]) {
  const ledger = process.env.DEVPANEL_TEST_PROCESS_LEDGER;
  if (ledger && owned.length) {
    for (const process of owned) cleanupIdentities.set(`${process.pid}:${process.startedAt}`, process);
    writeFileSync(join(ledger, `${process.pid}-cleanup.json`), JSON.stringify([...cleanupIdentities.values()]));
  }
  if (!owned.length) return;
  let remaining = owned;
  for (let i = 0; i < 100; i++) {
    const rows = await scanProcesses();
    remaining = discover(remaining, null, rows);
    if (!remaining.length) return;
    verifiedSignal(remaining, rows, "SIGKILL");
    await sleep(25);
  }
  assert.deepEqual(remaining.map(p => ({ pid: p.pid, startedAt: p.startedAt })), [], "test fixture processes must exit before cleanup completes");
}

const cleanedTaskServers = new WeakSet<object>();

export async function cleanupTaskServer(server: Awaited<ReturnType<typeof startServer>>, home: string) {
  if (cleanedTaskServers.has(server)) return;
  const owned = [...server.manager.runs.values()].flatMap(r => r.known);
  let processesStopped = false;
  let serverClosed = false;
  try { await server.manager.stopAllTasks(); }
  finally {
    try {
      owned.push(...[...server.manager.runs.values()].flatMap(r => r.known));
      await stopFixtureProcesses(owned);
      processesStopped = true;
    } finally {
      try { await server.close(); serverClosed = true; }
      finally {
        await rm(home, { recursive: true, force: true });
        if (processesStopped && serverClosed) cleanedTaskServers.add(server);
      }
    }
  }
}

/** Keep identities even after runs are pruned or a Manager is replaced. */
export function trackFixtureProcesses(manager: import("../../src/manager.ts").Manager) {
  const owned = new Map<string, ProcessInfo>();
  const capture = () => {
    for (const run of manager.runs.values()) for (const process of run.known)
      owned.set(`${process.pid}:${process.startedAt}`, process);
  };
  manager.on("event", capture);
  capture();
  return async () => { capture(); await stopFixtureProcesses([...owned.values()]); };
}

export async function until(check: () => boolean, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (!check() && Date.now() < deadline) await sleep(20);
  assert.ok(check(), `fixture condition must settle within ${timeoutMs}ms`);
}
