import { test } from "node:test";
import assert from "node:assert/strict";
import { Engine } from "../src/engine.ts";
import { addVirtualDir } from "../src/validate.ts";
import { seed } from "../src/seed.ts";
import { requestActor } from '../src/activity.ts';
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
test('mock supports work context, filtered activity, instance labels and strict context redaction', () => {
  const e = new Engine('/tmp/dp-mock-work');
  try {
    addVirtualDir('/virtual/work-a'); addVirtualDir('/virtual/work-b');
    const config = { schemaVersion: 1, name: 'work', root: '/virtual/work-a', instance: { group: 'demo', name: 'a' }, env: { TOKEN: { secret: true, value: 'private' } }, services: [{ id: 'web', name: 'web', cwd: '.', command: ['node', 'app.js'] }] };
    const actor = requestActor('cli', 'codex', 'work-a', encodeURIComponent('修复 private'));
    const a = e.register(config, actor).body.project;
    const b = e.register({ ...config, root: '/virtual/work-b', instance: { group: 'demo', name: 'b' } }, { ...actor, taskId: 'work-b' }).body.project;
    assert.notEqual(a.id, b.id);
    assert.deepEqual(e.view(e.getProj(a.id)).instance, { group: 'demo', name: 'a' });
    assert.equal(e.activity.page(a.id, null, 50, 'work-b').entries.length, 0);
    assert.equal(e.activity.page(a.id, null, 50, 'work-a').entries[0]!.actor.taskLabel, '修复 [REDACTED]');
    assert.equal(e.validate({ ...config, instance: { group: '', name: 'a' } }).ok, false);
    assert.deepEqual(requestActor('ui', undefined, 'bad id', '%ZZ'), { client: 'ui', agent: null });
    assert.throws(() => requestActor('cli', undefined, 'work-a', '%0A'));
  } finally { e.stop(); }
});
