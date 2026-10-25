import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDemo } from '../../../examples/demo/create-config.mjs';

test('bundled demo creates portable-location files without starting or overwriting', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dp-demo-'));
  try {
    const config = createDemo(join(dir, '中文 space'), '/example/node');
    const parsed = JSON.parse(readFileSync(config, 'utf8'));
    assert.equal(parsed.services[0].command[0], '/example/node');
    assert.equal(parsed.params[0].value, 0);
    assert.equal(parsed.services[0].ready.check.kind, 'log');
    assert.throws(() => createDemo(join(dir, '中文 space'), '/another/node'));
    assert.equal(JSON.parse(readFileSync(config, 'utf8')).services[0].command[0], '/example/node');
    assert.throws(() => createDemo(join(dir, 'bad'), '/example/node', 70000));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('demo entry runs through a symlink and paths containing spaces', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dp-demo-entry-'));
  try {
    const link = join(dir, 'linked examples');
    symlinkSync(fileURLToPath(new URL('../../../examples/demo', import.meta.url)), link);
    const target = join(dir, 'example 中文');
    const result = spawnSync(process.execPath, [join(link, 'create-config.mjs'), target], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(readFileSync(join(target, 'devpanel-demo.json'), 'utf8')).root, target);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
