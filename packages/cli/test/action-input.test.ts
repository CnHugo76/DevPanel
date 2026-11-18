import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, writeFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readActionParams, hasActionParams } from '../src/action-input.ts';
import { exportConfig, prepareImport } from '../src/portable-config.ts';
import type { ProjectConfig } from '@devpanel/contract';

test('action JSON/file inputs preserve false, zero, empty arrays and text literally', async t => {
  const root = await mkdtemp(join(tmpdir(), 'dp-action-input-')); t.after(() => rm(root, { recursive: true, force: true }));
  const values = { backup: false, count: 0, services: [], text: 'space " quote ${other} $(touch nope)\n中文' };
  const file = join(root, 'params.json'); await writeFile(file, JSON.stringify(values));
  assert.deepEqual(await readActionParams(JSON.stringify(values)), values);
  assert.deepEqual(await readActionParams(undefined, file), values);
  assert.equal(await readActionParams(), undefined);
  await assert.rejects(readActionParams('{}', file), /不能同时使用/);
  for (const bad of ['null', '[]', '"secret"', '{"__proto__":1}', '{"private":"never-echo"']) {
    await assert.rejects(readActionParams(bad), e => !String(e).includes('never-echo'));
  }
});

test('portable action secret defaults stay declared and only multiselect accepts arrays', () => {
  const config: ProjectConfig = { schemaVersion: 1, name: 'P', root: '/tmp/p', services: [{ id: 'web', name: 'Web', cwd: '.', command: ['node', 'web.mjs'] }], actions: [{ id: 'deploy', name: 'Deploy', cwd: '.', command: ['node', 'deploy.mjs', '${action.tokens}'], params: [
    { key: 'tokens', label: 'Tokens', type: 'multiselect', choices: [{ value: 'a' }, { value: 'b' }], secret: true, default: ['a'] },
    { key: 'password', label: 'Password', type: 'string', secret: true, default: 'never-share-this' },
  ] }] };
  assert.equal(hasActionParams(config), true); assert.equal(hasActionParams({ actions: [] }), false);
  const doc = exportConfig(config);
  assert.ok(!JSON.stringify(doc).includes('never-share-this'));
  assert.deepEqual(doc.project.actions![0]!.params![0]!.default, { secret: true });
  const multi = doc.inputs.find(i => i.target === '/actions/0/params/0/default')!, scalar = doc.inputs.find(i => i.target === '/actions/0/params/1/default')!;
  assert.equal(multi.valueType, 'multiselect');
  const values = { [multi.id]: ['b'], [scalar.id]: 'local-secret' };
  assert.deepEqual(prepareImport(doc, '/new', values).config.actions![0]!.params!.map(p => p.default), [['b'], 'local-secret']);
  assert.throws(() => prepareImport(doc, '/new', { ...values, [multi.id]: 'b' }), /类型/);
  assert.throws(() => prepareImport(doc, '/new', { ...values, [scalar.id]: ['b'] }), /类型/);
  assert.throws(() => prepareImport({ ...doc, inputs: [] }, '/new'), /秘密字段/);
});

test('CLI capability guard blocks POST to old daemon; stdin carries typed overrides to a new one', async t => {
  const home = await mkdtemp(join(tmpdir(), 'dp-ap-cli-')); await mkdir(join(home, 'run'));
  let capable = false;
  const requests: { path: string; method: string; body?: unknown }[] = [];
  const server = createServer(async (request, response) => {
    const chunks: Buffer[] = []; for await (const chunk of request) chunks.push(Buffer.from(chunk));
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : undefined;
    requests.push({ path: request.url!, method: request.method!, body });
    response.setHeader('content-type', 'application/json');
    if (request.url?.endsWith('/view')) response.end(JSON.stringify({ actions: [{ id: 'deploy', params: [{ key: 'backup', label: 'Backup', type: 'boolean' }] }] }));
    else if (request.url?.endsWith('/daemon')) response.end(JSON.stringify({ capabilities: capable ? ['action-params-v1'] : [] }));
    else { response.statusCode = 202; response.end(JSON.stringify({ created: true, run: { id: 'r_cli', state: 'running' } })); }
  });
  await new Promise<void>(r => server.listen(join(home, 'run/devpanel.sock'), r));
  t.after(async () => { server.closeAllConnections(); await new Promise<void>(r => server.close(() => r())); await rm(home, { recursive: true, force: true }); });
  const cli = resolve(import.meta.dirname, '../src/main.ts'), env = { ...process.env, DEVPANEL_HOME: home };
  await assert.rejects(promisify(execFile)(process.execPath, [cli, 'action', 'run', 'p', 'deploy', '--params', '{"backup":false}', '--json'], { env }), (error: any) => {
    assert.equal(error.code, 2); assert.match(JSON.parse(error.stdout).error.message, /不支持操作参数/); return true;
  });
  assert.ok(requests.every(r => r.method === 'GET'));
  capable = true;
  await new Promise<void>((done, reject) => {
    const child = execFile(process.execPath, [cli, 'action', 'run', 'p', 'deploy', '--params-file', '-', '--if-revision', '7', '--no-wait', '--json'], { env, timeout: 10000 }, (error, stdout) => {
      try { assert.equal(error, null); assert.equal(JSON.parse(stdout).run.id, 'r_cli'); done(); } catch (e) { reject(e); }
    });
    child.stdin!.end('{"backup":false,"count":0,"services":[]}');
  });
  assert.deepEqual(requests.find(r => r.method === 'POST')?.body, { params: { backup: false, count: 0, services: [] }, ifRevision: 7 });
});
