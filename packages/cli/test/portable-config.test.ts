import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { ProjectConfig } from '@devpanel/contract';
import { exportConfig, prepareImport, readConfigFile, saveExport, hideInputs } from '../src/portable-config.ts';

const config = (): ProjectConfig => ({ schemaVersion: 1, name: 'shared', root: '/old/project', env: { TOKEN: { secret: true, value: 'not-for-sharing' }, CACHE: '/old/cache', URL: 'http://127.0.0.1:8080' }, services: [{ id: 'web', name: 'web', cwd: '/old/project/sub', command: ['/old/node', 'server.mjs', '--data=/old/data'], env: { SERVICE_TOKEN: { secret: true } } }], actions: [{ id: 'build', name: 'build', cwd: '/outside', command: ['node', 'build.mjs'] }], params: [{ key: 'password', label: 'Password', type: 'number', secret: true, value: 123456, setBy: 'user', usedBy: [] }, { key: 'data', label: 'Data', type: 'string', value: '/private/data' }] });

test('portable export removes secrets, machine paths and response metadata; all inputs refill at a new root', () => {
  const exported = exportConfig(config());
  const json = JSON.stringify(exported);
  for (const text of ['not-for-sharing', '123456', '/old/', '/outside', '/private/data', 'setBy', 'usedBy']) assert.ok(!json.includes(text), text);
  assert.equal(exported.project.services[0]!.cwd, 'sub');
  assert.equal(exported.project.env!.URL, 'http://127.0.0.1:8080');
  assert.equal(prepareImport(exported, '/new/root').missing.length, exported.inputs.length);
  const values = Object.fromEntries(exported.inputs.map(i => [i.id, i.valueType === 'number' ? 654321 : i.kind === 'secret' ? 'new-secret' : '/new/path']));
  const prepared = prepareImport(exported, '/new/root', values);
  assert.equal(prepared.missing.length, 0);
  assert.equal(prepared.config.root, '/new/root');
  assert.deepEqual(prepared.config.env!.TOKEN, { secret: true, value: 'new-secret' });
  assert.equal(prepared.config.params![0]!.value, 654321);
  assert.equal(prepared.config.services[0]!.command[0], '/new/path');
});

test('portable input targets cannot mutate structure or prototypes; duplicate and undeclared secrets fail', () => {
  const exported = exportConfig(config());
  for (const target of ['/root', '/services/0/command', '/services/0/command/100', '/services/0/command/01', '/services/0/env', '/__proto__/x', '/services/0/constructor/x', '/params/0/secret', '/env/TOKEN', '/name']) {
    const document = structuredClone(exported); document.inputs[0]!.target = target;
    assert.throws(() => prepareImport(document, '/new'), target);
  }
  const duplicate = structuredClone(exported); duplicate.inputs.push({ ...duplicate.inputs[0]!, id: 'another' });
  assert.throws(() => prepareImport(duplicate, '/new'), /重复/);
  assert.throws(() => prepareImport({ ...exported, inputs: [] }, '/new'), /秘密字段/);
  assert.throws(() => prepareImport(exported, '/new', { unknown: 'x' }), /未声明/);
  assert.throws(() => prepareImport(exported, '/new', { [exported.inputs[0]!.id]: {} }), /标量/);
  const inline = structuredClone(exported); (inline.project.env!.TOKEN as any).value = 'inline-secret';
  assert.throws(() => prepareImport(inline, '/new'), /独立本机输入/);
  assert.throws(() => prepareImport(JSON.parse('{"format":"devpanel.project","version":1,"project":{"__proto__":{}} ,"inputs":[]}'), '/new'), /不允许/);
  assert.equal(({} as any).polluted, undefined);
  assert.throws(() => exportConfig({ ...config(), maven: { executable: '/private/mvn' as any } }), /auto/);
  assert.throws(() => exportConfig({ ...config(), repositories: [{ id: 'r', name: 'r', path: '/private/repo' }] }), /相对路径/);
});

test('file reads are bounded and export refuses to replace an existing file', async t => {
  const root = await mkdtemp(join(tmpdir(), 'dp-portable-')); t.after(() => rm(root, { recursive: true, force: true }));
  const file = join(root, 'devpanel.json'); saveExport(file, exportConfig(config()));
  assert.equal((readConfigFile(file) as any).version, 1);
  assert.throws(() => saveExport(file, exportConfig(config())), /已存在/);
  await writeFile(join(root, 'inputs.json'), ' '.repeat(65537));
  assert.throws(() => readConfigFile(join(root, 'inputs.json'), 65536), /大小限制/);
  assert.equal(JSON.stringify(hideInputs({ issues: ['missing /new/path and a-secret'] }, { a: '/new/path', b: 'a-secret' })).includes('/new/path'), false);
});
