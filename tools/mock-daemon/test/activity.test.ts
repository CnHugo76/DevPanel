import { test } from "node:test";
import assert from "node:assert/strict";
import { Engine } from "../src/engine.ts";
import { addVirtualDir } from "../src/validate.ts";
import { seed } from "../src/seed.ts";
test("mock 动态始终提供来源、敏感差异遮盖与所有种子来源", () => {
  const e = new Engine("/tmp/dp-mock-actor");
  try {
    seed(e);
    const page = e.activity.page(e.projects[0]!.project.id, null);
    assert.deepEqual(
      new Set(page.entries.map((x) => x.actor.agent ?? x.actor.client)),
      new Set(["claude-code", "codex", "cli", "ui", "daemon"]),
    );
    assert.equal(JSON.stringify(page).includes("private"), false);
    addVirtualDir("/virtual/actor");
    const config = {
      schemaVersion: 1,
      name: "actor",
      root: "/virtual/actor",
      services: [
        { id: "web", name: "web", cwd: ".", command: ["node", "app.js"] },
      ],
    };
    const p = e.register(config, { client: "cli", agent: "codex" }).body
      .project;
    assert.equal(e.activity.page(p.id, null).entries[0]!.actor.agent, "codex");
    e.register(config);
    assert.equal(e.activity.page(p.id, null).entries.length, 1);
    e.remove(p.id);
    assert.equal(e.activity.page(p.id, null).entries.length, 0);
  } finally {
    e.stop();
  }
});
