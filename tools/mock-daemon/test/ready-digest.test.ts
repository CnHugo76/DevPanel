import { test } from "node:test";
import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import {
  noReady,
  readyIssues,
  readySnapshot,
  logEvidence,
  portEvidence,
} from "../src/ready.ts";
import { sampleDigest } from "../src/digest.ts";
import type { ProjectConfig } from "@devpanel/contract";

test("mock 就绪只模拟契约的文字/虚拟端口与非敏感选项", () => {
  const config = {
    params: [{ key: "port", type: "number", value: 8080 }],
  } as ProjectConfig;
  const ready = { check: { kind: "port" as const, port: "${port}" } };
  assert.deepEqual(readyIssues(ready, config, "ready"), []);
  assert.equal((readySnapshot(config, ready)!.check as any).port, 8080);
  config.params![0]!.secret = true;
  assert.equal(readyIssues(ready, config, "ready")[0]!.code, "PARAM_INVALID");
  assert.equal(noReady().state, "not-configured");
  const tracking = {
    config: { check: { kind: "log" as const, contains: ["READY"] } },
    seq: 0,
    tails: {},
  };
  assert.equal(
    logEvidence(tracking, { seq: 1, ts: "now", stream: "sys", text: "READY" }),
    null,
  );
  assert.deepEqual(
    logEvidence(tracking, {
      seq: 2,
      ts: "now",
      stream: "out",
      text: "\x1b[32mREADY\x1b[0m",
    }),
    { kind: "log", seq: 2 },
  );
  assert.deepEqual(
    portEvidence({ check: { kind: "port" } }, [
      {
        port: 8080,
        pid: 1,
        address: "127.0.0.1",
        family: "ipv4",
        scope: "loopback",
      },
    ]),
    { kind: "port", port: 8080, address: "127.0.0.1" },
  );
});
test("mock 摘要是固定样例，参数校验与运行信息仍一致", () => {
  const result = sampleDigest(
    "r_mock",
    false,
    new URLSearchParams("maxBytes=1024"),
  );
  assert.equal(result.runId, "r_mock");
  assert.equal(result.runEnded, false);
  assert.ok(result.omitted.errorBlocks > 0);
  assert.ok(Buffer.byteLength(JSON.stringify(result.blocks)) <= 1024);
  assert.equal(
    sampleDigest("r", true, new URLSearchParams("afterSeq=10")).afterSeq,
    10,
  );
  assert.throws(() =>
    sampleDigest("r", true, new URLSearchParams("maxBytes=1")),
  );
});
test("mock 实现不导入 daemon 包或源码", async () => {
  const root = new URL("../src/", import.meta.url);
  for (const name of await readdir(root))
    if (name.endsWith(".ts"))
      assert.doesNotMatch(
        await readFile(new URL(name, root), "utf8"),
        /(?:from|import\()\s*["'][^"']*(?:packages\/daemon|@devpanel\/daemon)/,
        name,
      );
});
