import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import type { ActionConfig, ProjectConfig } from '@devpanel/contract';
import { actionDefinitionIssues, actionSensitive, expandAction, keepActionDefaults, maskAction, resolveActionRun } from '../src/action-params.ts';
import { mask, validate } from '../src/config.ts';
import { startServer } from '../src/server.ts';
import { Manager } from '../src/manager.ts';
import { limits, sleep } from '../src/storage.ts';
import { cleanupTaskServer } from './helpers/cleanup.ts';

const deploy = (): ActionConfig => ({ id: 'deploy', name: '示例打包部署', cwd: '.', command: [process.execPath, '-e', 'console.log(JSON.stringify({args:process.argv.slice(1),backup:process.env.BACKUP}))', '${action.services}', '${mode}'], env: { BACKUP: '${action.backup}' }, params: [
  { key: 'services', label: '部署服务', type: 'multiselect', required: true, choices: [{ value: 'front', label: '前端' }, { value: 'back', label: '后端' }, { value: 'runtime', label: 'Runtime' }], default: ['front', 'back'] },
  { key: 'backup', label: '备份数据库', type: 'boolean', default: true },
] });
const config = (root: string, action = deploy()): ProjectConfig => ({ schemaVersion: 1, name: 'fixture', root, services: [{ id: 'idle', name: 'idle', cwd: '.', command: [process.execPath, '-e', '0'] }], actions: [action], params: [{ key: 'mode', label: 'Mode', type: 'string', value: 'project-mode' }] });

test('action definitions and run inputs enforce types, defaults, required fields and namespaces', () => {
  const a = deploy();
  assert.deepEqual(resolveActionRun(a, {}, 1).snapshot.map(p => p.value), [['front', 'back'], true]);
  const override = resolveActionRun(a, { params: { services: ['runtime', 'back'], backup: false } }, 1);
  assert.deepEqual(override.snapshot.map(p => p.value), [['back', 'runtime'], false]);
  for (const params of [{ services: [] }, { services: ['invalid'] }, { services: ['back', 'back'] }, { backup: 'false' }, { backup: null }, { extra: true }]) assert.throws(() => resolveActionRun(a, { params }, 1), e => (e as any).code === 'CONFIG_INVALID');
  for (const input of [null, [], { extra: 'secret-input' }, { ifRevision: 0 }, { params: [] }]) assert.throws(() => resolveActionRun(a, input, 1), e => (e as any).code === 'BAD_REQUEST');
  assert.throws(() => resolveActionRun(a, { ifRevision: 2 }, 1), e => (e as any).code === 'REVISION_MISMATCH');
  a.params!.push({ key: 'required', label: 'Required', type: 'string', required: true }, { key: 'count', label: 'Count', type: 'number', min: 0, max: 2 }, { key: 'choice', label: 'Choice', type: 'enum', choices: [{ value: 'one' }] });
  assert.equal(actionDefinitionIssues(config('/tmp', a)).filter(i => i.severity === 'error').length, 0);
  assert.throws(() => resolveActionRun(a, {}, 1));
  assert.equal(resolveActionRun(a, { params: { required: 'text', count: 0, choice: 'one' } }, 1).values.count?.value, 0);
  for (const value of ['1', 3, Infinity]) assert.throws(() => resolveActionRun(a, { params: { required: 'text', count: value } }, 1));
  a.command[0] = '${action.services}';
  assert.ok(actionDefinitionIssues(config('/tmp', a)).some(i => i.path.endsWith('command[0]') && i.severity === 'error'));
});

test('one-pass argv expansion preserves literals, shell contexts and independent project keys', async () => {
  const literal = "空 格 '\"; $(touch impossible) ${mode} ${action.value}\n第二行";
  const a: ActionConfig = { id: 'shell', name: 'shell', cwd: '.', command: ['/bin/sh', '-c', 'printf "%s" "${action.value}"'], params: [{ key: 'value', label: '值', type: 'string', required: true }] };
  const c = config('/tmp', a), values = resolveActionRun(a, { params: { value: literal } }, 1).values;
  const expanded = expandAction(c, a, values);
  const result = await promisify(execFile)(expanded.command[0]!, expanded.command.slice(1));
  assert.equal(result.stdout, literal);
  for (const script of ['printf "%s" ${action.value}', "printf '%s' '${action.value}'", 'printf "%s" \\${action.value}', 'printf "%s" "\\${action.value}"']) {
    a.command[2] = script;
    const command = expandAction(c, a, values).command;
    const output = await promisify(execFile)(command[0]!, command.slice(1));
    assert.equal(output.stdout, (script.includes('\\${') ? '\\' : '') + literal);
  }
  a.command = [process.execPath, '-e', '0', '${action.value}', '$${action.value}', '${mode}'];
  assert.deepEqual(expandAction(c, a, values).command.slice(3), [literal, '${action.value}', 'project-mode']);
});

test('secret defaults can be kept or removed; malformed definitions and unknown PATH remain safe', () => {
  const a = deploy();
  a.params!.push({ key: 'token', label: 'Token', type: 'string', secret: true, default: 'private-default' });
  const previous = config('/tmp', a), incoming = config('/tmp', maskAction(a));
  assert.equal(actionDefinitionIssues(incoming, previous, true).some(i => i.severity === 'error'), false);
  keepActionDefaults(incoming, previous);
  assert.equal(incoming.actions![0]!.params!.at(-1)!.default, 'private-default');
  delete incoming.actions![0]!.params!.at(-1)!.default;
  keepActionDefaults(incoming, previous);
  assert.equal(incoming.actions![0]!.params!.at(-1)!.default, undefined);
  assert.ok(actionDefinitionIssues(config('/tmp', maskAction(a)), undefined, true).some(i => i.severity === 'error'));
  for (const choices of [null, {}, [null], ['x']]) for (const type of ['enum', 'multiselect']) {
    const invalid = { ...a, params: [{ key: 'bad', label: 'Bad', type, choices, default: type === 'enum' ? 'x' : ['x'] }] } as any;
    assert.ok(actionDefinitionIssues(config('/tmp', invalid)).some(i => i.severity === 'error'));
  }
  a.command[0] = 'node'; a.env = { PATH: '${action.path}' };
  a.params!.push({ key: 'path', label: 'Path', type: 'string', required: true });
  const validation = validate(config('/tmp', a), { PATH: '/usr/bin:/bin' });
  assert.equal(validation.ok, true);
  assert.equal(validation.services.find(s => s.serviceId === 'action:deploy')?.programResolved, null);
  assert.equal(validation.services.find(s => s.serviceId === 'action:deploy')?.pathUsed, '');
  assert.ok(actionSensitive({ n: { secret: true, value: 1e21 }, text: { secret: true, value: 'quote"\nvalue' } }).includes('1000000000000000000000'));
  assert.ok(actionSensitive({ text: { secret: true, value: 'quote"\nvalue' } }).includes('quote\\"\\nvalue'));
  const multiple = structuredClone(a);
  multiple.params!.push({ key: 'tags', label: 'Tags', type: 'multiselect', secret: true, default: ['deploy', 'multiselect'], choices: [{ value: 'deploy', label: '公开候选项' }, { value: 'multiselect' }] });
  (multiple.params!.at(-1)!.choices![0] as any).extra = 'private-default';
  const masked = mask(config('/tmp', multiple)).actions![0]!.params!.at(-1)!;
  assert.deepEqual(masked.default, { secret: true });
  assert.equal(masked.choices![0]!.value, 'deploy');
  assert.equal(masked.type, 'multiselect');
  assert.equal((masked.choices![0] as any).extra, '[REDACTED]');
  assert.equal(mask(config('/tmp', multiple)).actions![0]!.id, 'deploy');
});

test('API and CLI execute isolated overrides; history, secrets, concurrent requests and restart keep snapshots', async t => {
  const home = await mkdtemp(join(tmpdir(), 'dp-ap-'));
  const server = await startServer(home, 0, { ...limits, statsIntervalMs: 100 });
  t.after(() => cleanupTaskServer(server, home));
  const m = server.manager, a = deploy();
  a.params!.push({ key: 'token', label: '密钥', type: 'string', secret: true, required: true }, { key: 'secretList', label: '列表', type: 'multiselect', choices: [{ value: 'private-list-value' }], secret: true });
  a.command.splice(3, 0, '${action.token}', '${action.secretList}');
  const p = m.register(config(home, a)).project, before = JSON.stringify(m.project(p.id));
  const discovery = JSON.parse(await readFile(join(home, 'daemon.json'), 'utf8'));
  const call = async (input: unknown) => {
    const response = await fetch(`http://127.0.0.1:${server.httpPort}/api/v1/projects/${p.id}/actions/deploy/runs`, { method: 'POST', headers: { authorization: `Bearer ${discovery.token}`, 'X-DevPanel-Client': 'cli', 'Content-Type': 'application/json' }, body: JSON.stringify(input) });
    return { status: response.status, data: await response.json() as any };
  };
  assert.ok(m.info().capabilities?.includes('action-params-v1'));
  assert.equal((await call({})).status, 422); assert.equal(m.runs.size, 0);
  const run = await call({ ifRevision: 1, params: { services: ['runtime', 'back'], backup: false, token: 'private-token-value', secretList: ['private-list-value'] } });
  assert.equal(run.status, 202);
  const rid = run.data.run.id;
  for (let i = 0; i < 120 && !m.taskDetail(rid).endedAt; i++) { await sleep(25); await m.refresh(); }
  assert.equal(m.taskDetail(rid).state, 'succeeded');
  const detail = m.taskDetail(rid);
  assert.deepEqual(detail.actionParams!.slice(0, 2).map(p => p.value), [['back', 'runtime'], false]);
  assert.deepEqual(detail.actionParams!.at(-1)!.value, { secret: true });
  assert.equal(JSON.stringify(m.project(p.id)), before);
  const output = JSON.stringify([detail, m.activity.page(p.id, null, 50), m.logs.page(rid, new URLSearchParams(), true), m.logs.digest(rid, new URLSearchParams(), true)]);
  assert.ok(!output.includes('private-token-value')); assert.ok(!output.includes('private-list-value'));
  assert.ok(m.logs.page(rid, new URLSearchParams(), true).lines.some(l => l.text.includes('"backup":"false"')));
  const restoredHome = join(home, 'restored'); await mkdir(restoredHome); m.save(); await writeFile(join(restoredHome, 'state.json'), await readFile(join(home, 'state.json')));
  const restored = new Manager(restoredHome, m.boot); t.after(() => restored.close());
  assert.deepEqual(restored.taskDetail(rid).actionParams, detail.actionParams);
  const c = config(home, { ...deploy(), command: [process.execPath, '-e', 'setTimeout(()=>{},10000)', '${action.services}'] });
  c.actions![0]!.params!.push({ key: 'privateChoice', label: 'Sensitive choice', type: 'enum', secret: true, default: 'private-candidate-id', choices: [{ value: 'private-candidate-id', label: '公开候选项' }] });
  m.update(p.id, { ifRevision: 1, config: c });
  const definitions = m.safe(m.view(p.id).actions);
  assert.deepEqual(definitions[0]!.params!.at(-1)!.choices, [{ value: 'private-candidate-id', label: '公开候选项' }]);
  assert.deepEqual(definitions[0]!.params!.at(-1)!.default, { secret: true });
  const apiView = await fetch(`http://127.0.0.1:${server.httpPort}/api/v1/projects/${p.id}/view`, { headers: { authorization: `Bearer ${discovery.token}` } }).then(r => r.json()) as any;
  assert.equal(apiView.actions[0].params.at(-1).choices[0].value, 'private-candidate-id');
  const running = await m.startAction(p.id, 'deploy', { client: 'cli', agent: null }, { params: { services: ['back'] } });
  assert.deepEqual(m.taskDetail(running.run.id).actionParams!.at(-1)!.value, { secret: true });
  assert.equal((await m.startAction(p.id, 'deploy', { client: 'cli', agent: null }, { params: { services: ['back'] } })).created, false);
  await assert.rejects(() => m.startAction(p.id, 'deploy', { client: 'cli', agent: null }, { params: { services: ['front'] } }), e => (e as any).error.code === 'TASK_RUNNING');
  await m.cancelTask(running.run.id, false);
  for (let i = 0; i < 120 && !m.taskDetail(running.run.id).endedAt; i++) { await sleep(25); await m.refresh(); }
  m.update(p.id, { ifRevision: 2, config: config(home) });
  const cli = resolve(import.meta.dirname, '../../cli/src/main.ts');
  const result = await promisify(execFile)(process.execPath, [cli, 'action', 'run', p.id, 'deploy', '--params', '{"services":["runtime"],"backup":false}', '--if-revision', '3', '--json'], { env: { ...process.env, DEVPANEL_HOME: home }, timeout: 10000 });
  assert.equal(JSON.parse(result.stdout).state, 'succeeded');
});
