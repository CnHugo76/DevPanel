import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ProjectConfig } from "@devpanel/contract";
import {
  expandService,
  formatValue,
  prepareParams,
  inlineParam,
} from "../src/params.ts";
import { validate } from "../src/config.ts";

test("param validation rejects malformed metadata and accepts unresolved secret executable/PATH", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "devpanel-params-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const config: ProjectConfig = {
    schemaVersion: 1,
    name: "params",
    root,
    services: [
      { id: "app", name: "App", cwd: ".", command: [process.execPath] },
    ],
  };
  for (const params of [
    null,
    {},
    [null],
    [
      {
        key: "value",
        label: "Value",
        type: "enum",
        value: "x",
        choices: "bad",
      },
    ],
    [
      {
        key: "value",
        label: "Value",
        type: "number",
        value: 2,
        min: 5,
        max: 1,
      },
    ],
  ]) {
    const result = validate({ ...config, params }, { PATH: "/bin" });
    assert.equal(result.ok, false);
    assert.ok(result.issues.some((i) => i.code === "PARAM_INVALID"));
  }
  config.params = [
    { key: "bin", label: "Binary", type: "string", secret: true },
  ];
  config.services[0]!.command = ["${bin}/node"];
  assert.equal(validate(config, { PATH: "/bin" }).ok, true);
  assert.equal(validate(config, { PATH: "/bin" }, undefined, "save").ok, false);
  config.services[0]!.command = ["node"];
  config.env = { PATH: "${bin}" };
  const result = validate(config, { PATH: "/bin" });
  assert.equal(result.ok, true);
  assert.equal(result.services[0]!.pathUsed, "");
  assert.equal(result.services[0]!.programResolved, null);
});

test("parameter expansions are single pass and shell detection uses the resolved executable", () => {
  const config: ProjectConfig = {
    schemaVersion: 1,
    name: "p",
    root: "/",
    params: [
      { key: "shell", label: "Shell", type: "string", value: "/bin/zsh" },
      { key: "v", label: "Value", type: "string", value: "a' $${shell}" },
    ],
    services: [
      {
        id: "app",
        name: "App",
        cwd: ".",
        command: ["${shell}", "-lc", 'printf "%s" ${v}'],
        env: { KEEP: { secret: true, value: "${v}" } },
      },
    ],
  };
  const expanded = expandService(config, config.services[0]!);
  assert.equal(expanded.command[2], "printf \"%s\" 'a'\\'' $${shell}'");
  assert.deepEqual(expanded.env!.KEEP, { secret: true, value: "${v}" });
  inlineParam(config, "v");
  config.params = config.params!.filter((p) => p.key !== "v");
  assert.equal(
    expandService(config, config.services[0]!).command[2],
    expanded.command[2],
  );
  assert.equal(formatValue(1e21), "1000000000000000000000");
  assert.equal(formatValue(-1e-7), "-0.0000001");
});

test("response metadata cannot spoof setters and description edits preserve the value timestamp", () => {
  const config: ProjectConfig = {
    schemaVersion: 1,
    name: "p",
    root: "/",
    services: [],
    params: [
      {
        key: "v",
        label: "Old",
        type: "string",
        secret: true,
        value: "private",
        setBy: "user",
        describedBy: "agent",
        valueUpdatedAt: "old-time",
      },
    ],
  };
  const incoming = structuredClone(config);
  incoming.params![0]!.label = "New";
  incoming.params![0]!.setBy = "agent";
  const result = prepareParams(incoming, config, "ui", false).config
    .params![0]!;
  assert.equal(result.setBy, "user");
  assert.equal(result.valueUpdatedAt, "old-time");
  assert.equal(result.describedBy, "user");
  incoming.params![0]!.value = "replaced";
  incoming.params![0]!.secret = false;
  const protectedResult = prepareParams(incoming, config, "cli", true);
  assert.deepEqual(protectedResult.kept, ["v"]);
  assert.equal(protectedResult.config.params![0]!.secret, true);
});

test("clarifications: only legal closed keys are placeholders; secret-only references suppress warnings", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "devpanel-clarifications-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const config: ProjectConfig = {
    schemaVersion: 1,
    name: "p",
    root,
    params: [
      {
        key: "secret",
        label: "Secret",
        type: "string",
        secret: true,
        value: "private",
      },
      { key: "plain", label: "Plain", type: "string", value: "plain" },
    ],
    env: {
      HF_TOKEN: "${secret}",
      TWO_KEYS: "${secret}${secret}",
      MIXED_TOKEN: "${secret}${plain}",
      PREFIX_TOKEN: "prefix-${secret}",
      ESCAPED_TOKEN: "$${secret}",
      SECRET_LIKE: "${secret:-default}",
    },
    services: [
      {
        id: "app",
        name: "App",
        cwd: ".",
        command: [
          process.execPath,
          "${a:-b}",
          "${}",
          "${",
          "${1bad}",
          "${a-b}",
          "${" + "a".repeat(33) + "}",
          "$${HOME}",
        ],
      },
    ],
  };
  const result = validate(config, { PATH: "/bin" });
  assert.equal(result.ok, true);
  assert.deepEqual(
    result.issues
      .filter((i) => i.code === "WARN_SECRET_LIKE_PLAIN")
      .map((i) => i.path),
    [
      "env.MIXED_TOKEN",
      "env.PREFIX_TOKEN",
      "env.ESCAPED_TOKEN",
      "env.SECRET_LIKE",
    ],
  );
  const expanded = expandService(config, config.services[0]!);
  assert.deepEqual(expanded.command.slice(1), [
    ...config.services[0]!.command.slice(1, -1),
    "${HOME}",
  ]);
  config.services[0]!.command.push("${HOME}");
  assert.ok(
    validate(config, { PATH: "/bin" }).issues.some(
      (i) => i.code === "PARAM_UNKNOWN",
    ),
  );
});
