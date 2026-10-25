import { test } from "node:test";
import assert from "node:assert/strict";
import { redact } from "../src/config.ts";

test("response redaction preserves short substrings but masks whole values and long fragments", () => {
  assert.deepEqual(
    redact(
      {
        name: "fixture",
        pathUsed: "/example/bin",
        exact: "x",
        nested: ["x", "prefix-x"],
        long: "prefix-abcdefgh-suffix",
      },
      ["x", "abcdefgh"],
    ),
    {
      name: "fixture",
      pathUsed: "/example/bin",
      exact: "[REDACTED]",
      nested: ["[REDACTED]", "prefix-x"],
      long: "prefix-[REDACTED]-suffix",
    },
  );
  assert.equal(redact("prefix-1234567", ["1234567"]), "prefix-1234567");
  assert.equal(redact("1234567", ["1234567"]), "[REDACTED]");
  assert.equal(redact("prefix-12345678", ["12345678"]), "prefix-[REDACTED]");
  assert.equal(redact("prefix-秘密密码", ["秘密密码"]), "prefix-秘密密码");
  assert.equal(redact("prefix-x", ["x"], 1), "prefi[REDACTED]-[REDACTED]");
});

test("redaction treats regex characters literally, matches longest first and never rewrites inserted markers", () => {
  assert.equal(
    redact("begin a.*[b]\\c end", ["a.*[b]\\c"]),
    "begin [REDACTED] end",
  );
  assert.equal(redact("fixture", ["x", "R"], 1), "fi[REDACTED]ture");
  assert.equal(
    redact("prefix-abcdefghijk", ["abcdefgh", "abcdefghijk"]),
    "prefix-[REDACTED]",
  );
  assert.equal(redact("fixture", [""]), "fixture");
});
