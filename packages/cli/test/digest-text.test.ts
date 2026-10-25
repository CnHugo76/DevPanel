import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { digestText } from "../src/digest-text.ts";
const root = new URL("../../../test-fixtures/digest/", import.meta.url);
for (const name of readdirSync(root).filter((n) => n.endsWith(".json")))
  test(`共同摘要golden：${name}`, () => {
    assert.equal(
      digestText(JSON.parse(readFileSync(new URL(name, root), "utf8"))) + "\n",
      readFileSync(
        fileURLToPath(new URL(name.replace(/\.json$/, ".txt"), root)),
        "utf8",
      ),
    );
  });
