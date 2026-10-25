import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { DaemonEvent, ProcessInfo } from "@devpanel/contract";
import { Manager } from "../../src/manager.ts";

// Test-only preload: persist identities before managers/history can discard them.
const ledger = process.env.DEVPANEL_TEST_PROCESS_LEDGER;
if (ledger) {
  const owned = new Map<string, ProcessInfo>();
  const event = Manager.prototype.event;
  Manager.prototype.event = function (value: DaemonEvent) {
    let changed = false;
    for (const run of this.runs.values())
      for (const process of run.known) {
        const key = `${process.pid}:${process.startedAt}`;
        if (!owned.has(key)) {
          owned.set(key, process);
          changed = true;
        }
      }
    if (changed)
      writeFileSync(
        join(ledger, `${process.pid}.json`),
        JSON.stringify([...owned.values()]),
      );
    return event.call(this, value);
  };
}
