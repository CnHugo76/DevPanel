import { test } from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stableNodePath } from "../src/node-path.ts";

test("Node path resolution handles versioned/unversioned Homebrew formulas and keeps non-Homebrew paths", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "devpanel-node-path-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  for (const [prefix, formula] of [["opt/homebrew", "node@24"], ["usr/local", "node"]]) {
    const brew = join(root, prefix!);
    const bin = join(brew, "opt", formula!, "bin");
    await mkdir(bin, { recursive: true });
    await symlink(process.execPath, join(bin, "node"));
    assert.equal(stableNodePath(join(brew, "Cellar", formula!, "24.21.0/bin/node")), join(bin, "node"));
  }
  assert.equal(stableNodePath("/custom/bin/node"), "/custom/bin/node");
  assert.equal(stableNodePath("/custom/opt/node@24/bin/node"), "/custom/opt/node@24/bin/node");
});

test("missing or non-executable Homebrew opt paths fail instead of pinning the old keg", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "devpanel-node-path-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const executable = join(root, "Cellar/node@24/24.21.0/bin/node");
  assert.throws(() => stableNodePath(executable), /稳定路径/);
  const bin = join(root, "opt/node@24/bin");
  await mkdir(bin, { recursive: true });
  await writeFile(join(bin, "node"), "not executable");
  await chmod(join(bin, "node"), 0o600);
  assert.throws(() => stableNodePath(executable), /稳定路径/);
});
