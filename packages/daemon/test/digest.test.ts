import { test } from "node:test";
import assert from "node:assert/strict";
import { digest, errorTitle } from "../src/digest.ts";
import type { LogLine } from "@devpanel/contract";
const lines = (texts: string[]): LogLine[] =>
  texts.map((text, i) => ({
    seq: i + 1,
    ts: new Date(0).toISOString(),
    stream: "err",
    text,
  }));
test("摘要识别严格的大写标题、异常与Python，并排除普通stderr", () => {
  for (const text of [
    "ERROR bad",
    "FATAL",
    "SEVERE",
    "java.lang.IllegalStateException: bad",
    "TypeError: bad",
    "Traceback (most recent call last):",
    "panic: bad",
  ])
    assert.ok(errorTitle(text), text);
  for (const text of [
    "error",
    "NO_ERROR",
    "ERRORS",
    "normal stderr",
    "xpanic:",
  ])
    assert.ok(!errorTitle(text), text);
});
test("数字归一化、重复、ANSI、堆栈边界、折叠及增量", () => {
  const input = lines([
    "\x1b[31mERROR port 8080\x1b[0m",
    ...Array.from({ length: 10 }, (_, i) => `    at File.f(File.java:${i})`),
    "Caused by: bad",
    "    at A",
    "    at B",
    "    at C",
    "normal",
    "normal",
    "ERROR port 9090",
    "    at X",
    "done",
  ]);
  const d = digest("r", input, true, true, new URLSearchParams());
  assert.equal(d.errorBlocks, 1);
  assert.equal(d.blocks[0]!.occurrences, 2);
  assert.equal(d.blocks[0]!.lastOccurrenceSeq, 18);
  assert.equal(d.blocks[0]!.lines[5]!.folded!.lines, 5);
  assert.equal(d.blocks[0]!.lastSeq, 15);
  assert.ok(d.blocks[0]!.lines.every((l) => !l.text.includes("\x1b")));
  assert.equal(
    d.blocks.at(-1)!.lines.find((l) => l.text === "normal")!.repeat,
    2,
  );
  assert.ok(d.truncated);
  const incremental = digest(
    "r",
    input,
    false,
    false,
    new URLSearchParams("afterSeq=17"),
  );
  assert.equal(incremental.scannedLines, 3);
});
test("Python缩进、超长UTF8及预算始终有上界", () => {
  const input = lines([
    "Traceback (most recent call last):",
    '  File "x.py", line 1',
    "    raise TypeError()",
    "TypeError: bad",
    ...Array.from(
      { length: 100 },
      (_, i) => `ERROR ${"字".repeat(800)} ${String.fromCharCode(65 + i)}`,
    ),
  ]);
  const d = digest(
    "r",
    input,
    false,
    true,
    new URLSearchParams("maxBytes=1024&tail=0"),
  );
  assert.ok(Buffer.byteLength(JSON.stringify(d.blocks)) <= 1024);
  assert.ok(d.omitted.bytes > 0);
  assert.ok(d.omitted.errorBlocks > 0);
  assert.equal(d.blocks[0]!.lines[2]!.text, "    raise TypeError()");
  for (const b of d.blocks)
    for (const l of b.lines) assert.ok(Buffer.byteLength(l.text) <= 1024);
});
test("参数与空摘要", () => {
  assert.throws(() =>
    digest("r", [], false, true, new URLSearchParams("maxBytes=1")),
  );
  assert.equal(
    digest("r", [], false, true, new URLSearchParams()).lastSeq,
    null,
  );
});

test("Python Traceback 包含异常行，按异常签名区分与去重", () => {
  const input = lines([
    "Traceback (most recent call last):",
    '  File "x.py", line 1',
    "    raise ValueError()",
    "ValueError: bad 1",
    "Traceback (most recent call last):",
    '  File "y.py", line 2',
    "    raise TypeError()",
    "TypeError: other",
    "Traceback (most recent call last):",
    '  File "x.py", line 3',
    "    raise ValueError()",
    "ValueError: bad 9",
  ]);
  const d = digest("r", input, false, true, new URLSearchParams("tail=0"));
  assert.equal(d.errorBlocks, 2);
  assert.deepEqual(
    d.blocks.map((b) => [
      b.firstSeq,
      b.lastSeq,
      b.occurrences,
      b.lastOccurrenceSeq,
    ]),
    [
      [1, 4, 2, 9],
      [5, 8, 1, 5],
    ],
  );
  assert.equal(d.blocks[0]!.lines.at(-1)!.text, "ValueError: bad 1");
});
test("预算优先保留最后一次发生的错误签名", () => {
  const input = lines([
    "ERROR first",
    "ERROR B " + "b".repeat(600),
    "ERROR C " + "c".repeat(600),
    "ERROR B " + "b".repeat(600),
  ]);
  const d = digest(
    "r",
    input,
    false,
    true,
    new URLSearchParams("maxBytes=1024&tail=0"),
  );
  assert.deepEqual(
    d.blocks.map((b) => b.firstSeq),
    [1, 2],
  );
  assert.equal(d.blocks[1]!.lastOccurrenceSeq, 4);
  assert.equal(d.omitted.errorBlocks, 1);
});

test("daemon 生成 CLI 与 Swift 共用的全部 golden", async () => {
  const { readdir, readFile } = await import("node:fs/promises");
  const root = new URL("../../../test-fixtures/digest/", import.meta.url);
  for (const name of (await readdir(root)).filter((name) =>
    name.endsWith(".input"),
  )) {
    const input = JSON.parse(await readFile(new URL(name, root), "utf8"));
    const expected = JSON.parse(
      await readFile(new URL(name.replace(/\.input$/, ".json"), root), "utf8"),
    );
    assert.deepEqual(
      digest(
        expected.runId,
        input.source,
        !!input.truncated,
        true,
        new URLSearchParams(input.params),
      ),
      expected,
      name,
    );
  }
});
