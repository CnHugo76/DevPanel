import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Logs } from "../src/logs.ts";
import { limits } from "../src/storage.ts";
test("redaction crosses writes, newlines and split lines; sequence reservation survives lost tail", async () => {
  const home = await mkdtemp(join(tmpdir(), "devpanel-logs-"));
  const small = { ...limits, logLineMaxBytes: 32, logBytesPerRun: 1024 };
  const logs = new Logs(home, small, () => {});
  let reserved = 1;
  logs.reserveSequence = (_id, end) => {
    reserved = end;
  };
  logs.create("r_test");
  const secret = "SENSITIVE\n" + "abcdef".repeat(20),
    collector = logs.collector("r_test", "out", [secret]);
  const input = Buffer.from("before " + secret + " after\n");
  for (let i = 0; i < input.length; i += 7)
    collector.write(input.subarray(i, i + 7));
  collector.end();
  const lines = logs.page("r_test", new URLSearchParams(), false).lines;
  const text = lines.map((l) => l.text).join("");
  assert.equal(text, "before [REDACTED] after");
  assert.ok(reserved > lines.at(-1)!.seq);
  await logs.close();
  const reopened = new Logs(home, small, () => {});
  reopened.create("r_test", reserved);
  reopened.add("r_test", "sys", "gap after recovery");
  assert.ok(reopened.info("r_test").lastSeq! >= reserved);
  await reopened.close();
  await rm(home, { recursive: true, force: true });
});

test("short secrets remain strictly redacted in streamed out and err logs", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "devpanel-short-log-"));
  const logs = new Logs(home, limits, () => {});
  t.after(async () => {
    await logs.close();
    await rm(home, { recursive: true, force: true });
  });
  logs.create("r_short");
  for (const stream of ["out", "err"] as const) {
    const collector = logs.collector("r_short", stream, ["x", "ab"]);
    collector.write(Buffer.from("token=x a"));
    collector.write(Buffer.from("b\n"));
    collector.end();
  }
  assert.deepEqual(
    logs.page("r_short", new URLSearchParams(), false).lines.map((l) => l.text),
    ["token=[REDACTED] [REDACTED]", "token=[REDACTED] [REDACTED]"],
  );
});

 test("日志摘要不会恢复secret环境或选项的原值", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "dp-digest-secret-"));
  const logs = new Logs(home, limits, () => {});
  t.after(async () => { await logs.close(); await rm(home,{recursive:true,force:true}); });
  logs.create("r_secret");
  const collector = logs.collector("r_secret", "err", ["env-secret-123", "param-secret-456"]);
  collector.write(Buffer.from("ERROR env-secret-123 param-secret-456\n")); collector.end();
  const json = JSON.stringify(logs.digest("r_secret",new URLSearchParams(),true));
  assert.ok(!json.includes("env-secret-123")); assert.ok(!json.includes("param-secret-456")); assert.ok(json.includes("[REDACTED]"));
});

test("完整换行不因secret固定尾巴而延迟，只有真正前缀续接才保留",async t=>{
 const home=await mkdtemp(join(tmpdir(),"dp-log-ready-"));const logs=new Logs(home,limits,()=>{});
 t.after(async()=>{await logs.close();await rm(home,{recursive:true,force:true});});logs.create("r_ready");
 const c=logs.collector("r_ready","out",["long-environment-secret","option-secret-value"]);
 c.write(Buffer.from("READY NOW\n"));
 assert.deepEqual(logs.page("r_ready",new URLSearchParams(),false).lines.map(l=>l.text),["READY NOW"]);
 c.write(Buffer.from("token=long-environ"));c.write(Buffer.from("ment-secret option-secret-value\n"));
 assert.deepEqual(logs.page("r_ready",new URLSearchParams(),false).lines.map(l=>l.text),["READY NOW","token=[REDACTED] [REDACTED]"]);
 c.end();
});
