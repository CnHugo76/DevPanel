import { appendFileSync } from "node:fs";
import { join } from "node:path";

/** Persist diagnostics even when launchd redirects stderr to /dev/null. */
export function daemonLog(home: string, line: string) {
  try {
    appendFileSync(join(home, "daemon.log"), line + "\n", { mode: 0o600 });
  } catch {
    // Logging must not change sampler health or break recovery.
    process.stderr.write(line + "\n");
  }
}
