import { test } from "node:test";
import assert from "node:assert/strict";
import {
  cleanupSmoke,
  assertNoSecrets,
} from "../../../scripts/release-smoke-cleanup.mjs";

test("smoke 停服务与停 daemon 抛错后仍核验进程", async () => {
  const calls: string[] = [];
  await assert.rejects(
    cleanupSmoke({
      stopProject: () => {
        calls.push("project");
        throw new Error("project failed");
      },
      stopDaemon: () => {
        calls.push("daemon");
        throw new Error("daemon failed");
      },
      audit: () => {
        calls.push("audit");
      },
    }),
    AggregateError,
  );
  assert.deepEqual(calls, ["project", "daemon", "audit"]);
});
test("smoke 敏感输出在收集与保存前拒绝，异常消息不携带值", () => {
  assert.throws(
    () => assertNoSecrets({ stdout: "private-sentinel" }, ["private-sentinel"]),
    (error) =>
      error instanceof Error && !error.message.includes("private-sentinel"),
  );
  assert.doesNotThrow(() =>
    assertNoSecrets({ stdout: "[REDACTED]" }, ["private-sentinel"]),
  );
});
