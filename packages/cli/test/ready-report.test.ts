import { test } from "node:test";
import assert from "node:assert/strict";
import { reportCode } from "../src/ready-report.ts";
import type { CliStartReport } from "@devpanel/contract";
function report(states: string[], state = "succeeded"): CliStartReport {
  return {
    operation: { state, results: [] } as any,
    services: states.map((ready, i) => ({
      serviceId: String(i),
      runId: "r",
      outcome: "started",
      ready: { state: ready, at: null, afterMs: null, evidence: null },
      listening: null,
      digest: null,
    })) as any,
  };
}
test("启动报告退出码优先级", () => {
  assert.equal(reportCode(report(["ready"])), 0);
  assert.equal(reportCode(report(["not-configured"])), 0);
  assert.equal(reportCode(report(["timed-out"])), 11);
  assert.equal(reportCode(report(["timed-out", "ended-before-ready"])), 1);
  assert.equal(reportCode(report(["waiting"]), true), 8);
  assert.equal(reportCode(report(["timed-out"], "partial")), 6);
  assert.equal(reportCode(report(["ready"], "failed")), 1);
});
