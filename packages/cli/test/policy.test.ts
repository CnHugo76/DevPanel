import { test } from "node:test";
import assert from "node:assert/strict";
import type { Operation } from "@devpanel/contract";
import { operationCode } from "../src/client.ts";
test("托管规则退出码只覆盖终态中全部失败为 POLICY_DENIED 的情况", () => {
  const op = (
    state: Operation["state"],
    codes: (string | null)[],
  ): Operation => ({
    id: "op_test",
    projectId: "p_test",
    action: "start",
    serviceIds: codes.map((_, i) => String(i)),
    source: "cli",
    state,
    createdAt: "",
    finishedAt: "",
    cancelledBy: null,
    results: codes.map((code, i) => ({
      serviceId: String(i),
      outcome: code ? "failed" : "started",
      runId: null,
      error: code ? { code: code as "POLICY_DENIED", message: "" } : null,
    })),
  });
  assert.equal(operationCode(op("failed", ["POLICY_DENIED"])), 12);
  assert.equal(operationCode(op("partial", [null, "POLICY_DENIED"])), 12);
  assert.equal(
    operationCode(op("partial", [null, "POLICY_DENIED", "SPAWN_FAILED"])),
    6,
  );
  assert.equal(
    operationCode(op("failed", ["POLICY_DENIED", "SPAWN_FAILED"])),
    1,
  );
  assert.equal(operationCode(op("running", [null, "POLICY_DENIED"])), 8);
});
