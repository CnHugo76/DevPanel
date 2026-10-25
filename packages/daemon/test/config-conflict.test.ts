import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Manager } from "../src/manager.ts";

test("CONFIG_CONFLICT 按路径返回差异，环境/选项/服务/任务敏感值全部遮盖", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "dp-conflict-"));
  const manager = new Manager(home, 1);
  t.after(async () => {
    await manager.close();
    await rm(home, { recursive: true, force: true });
  });
  const config = {
    schemaVersion: 1,
    name: "old",
    root: home,
    env: {
      TOKEN: { secret: true, value: "project-secret-old" },
      HIDDEN: "${hidden}",
    },
    params: [
      {
        key: "hidden",
        type: "string",
        label: "Hidden",
        secret: true,
        value: "param-secret-old",
      },
    ],
    services: [
      {
        id: "app",
        name: "app",
        cwd: ".",
        command: ["/usr/bin/true"],
        env: { TOKEN: { secret: true, value: "service-secret-old" } },
      },
    ],
    actions: [
      {
        id: "job",
        name: "job",
        cwd: ".",
        command: ["/usr/bin/true"],
        env: { TOKEN: { secret: true, value: "action-secret-old" } },
      },
    ],
  };
  manager.register(config);
  const changed = structuredClone(config);
  changed.name = "new";
  changed.env.TOKEN.value = "project-secret-new";
  changed.params[0]!.value = "param-secret-new";
  changed.services[0]!.env.TOKEN.value = "service-secret-new";
  changed.services[0]!.command.push("--flag");
  changed.actions[0]!.env.TOKEN.value = "action-secret-new";
  assert.throws(
    () => manager.register(changed),
    (error: any) => {
      assert.equal(error.error.code, "CONFIG_CONFLICT");
      const diff = error.error.details.diff;
      assert.deepEqual(
        new Set(diff.map((entry: any) => entry.path)),
        new Set([
          "name",
          "env.TOKEN",
          "params[0]",
          "services[0].env.TOKEN",
          "services[0].command[1]",
          "actions[0].env.TOKEN",
        ]),
      );
      for (const entry of diff.filter(
        (entry: any) =>
          entry.path.includes("TOKEN") || entry.path.startsWith("params"),
      ))
        assert.deepEqual(
          [entry.existing, entry.incoming],
          [{ secret: true }, { secret: true }],
        );
      assert.doesNotMatch(
        JSON.stringify(error.error),
        /(?:project|param|service|action)-secret-(?:old|new)/,
      );
      return true;
    },
  );
});
