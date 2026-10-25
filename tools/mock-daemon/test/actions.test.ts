import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import type { ProjectConfig, LogStreamEvent } from '@devpanel/contract';
import { Engine, DEFAULT_LIMITS } from '../src/engine.ts';
import { HttpError } from '../src/errors.ts';
import { addVirtualDir } from '../src/validate.ts';

const root = '/virtual/actions';
addVirtualDir(root);
const engines: Engine[] = [];
afterEach(() => engines.splice(0).forEach((e) => e.stop()));
function setup() {
  const e = new Engine('/tmp/devpanel-actions-test', { ...DEFAULT_LIMITS, taskRunsKept: 2, logBytesPerTaskRun: 128 });
  engines.push(e);
  e.taskSimulation.durationMs = 25;
  e.taskSimulation.cancelDelayMs = 5;
  const config: ProjectConfig = {
    schemaVersion: 1, name: 'Actions', root,
    params: [{ key: 'mode', label: 'Mode', type: 'string', value: 'local' }, { key: 'token', label: 'Token', type: 'string', value: 'secret-value', secret: true }],
    services: [{ id: 'server', name: 'Server', cwd: '.', command: ['node', 'server.js'] }],
    actions: [
      { id: 'build', name: 'Build', cwd: '.', command: ['node', 'build.js', '${mode}', '${token}'], env: { TOKEN: { secret: true, value: 'env-secret' } }, stopTimeoutSec: 1 },
      { id: 'fail-demo', name: 'Fail', cwd: '.', command: ['node', 'test.js'] },
    ],
  };
  const p = e.register(config).body.project;
  return { e, config, p };
}
async function ended(e: Engine, id: string) {
  for (let i = 0; i < 300; i++) { const r = e.taskDetail(id); if (r.endedAt) return r; await new Promise((resolve) => setTimeout(resolve, 10)); }
  throw new Error('task did not finish');
}

test('actions validate without running; refs, secrets, inline and keep markers follow services', () => {
  const { e, config, p } = setup();
  assert.deepEqual(p.config.params?.[0]?.usedBy, [{ serviceId: 'action:build', where: 'command', index: 2 }]);
  assert.deepEqual(p.config.actions?.[0]?.env?.TOKEN, { secret: true });
  assert.equal(e.actionRuns(p.id, 'build').length, 0);
  for (const patch of [{ timeoutSec: 0 }, { command: ['missing-program'] }, { command: ['node', '${missing}'] }, { confirmWhenServicesRunning: 'yes' }]) {
    assert.equal(e.validate({ ...config, actions: [{ ...config.actions![0], ...patch }] }).ok, false);
  }
  assert.equal(e.validate({ ...config, actions: [config.actions![0], config.actions![0]] }).ok, false);
  const updated = e.update(p.id, { ifRevision: 1, config: p.config }, { client: 'ui', agent: null });
  assert.equal(updated.revision, 1);
  const inlined = e.deleteParam(p.id, 'mode', { ifRevision: 1, inline: true });
  assert.equal(inlined.config.actions?.[0]?.command[2], 'local');
});

test('run lifecycle, idempotency, independent actions, logs, stats and retention', async () => {
  const { e, p } = setup();
  const started = e.startAction(p.id, 'build', { client: 'cli', agent: null });
  assert.equal(e.startAction(p.id, 'build', { client: 'ui', agent: null }).created, false);
  assert.equal(started.run.source, 'cli');
  const failed = e.startAction(p.id, 'fail-demo', { client: 'ui', agent: null });
  e.sampleAll();
  assert.equal(Object.keys(e.lastStats!.projects[p.id]!.tasks).length, 2);
  const detail = e.taskDetail(started.run.id);
  assert.equal(detail.command[3], '••••');
  assert.deepEqual(detail.params.token, { secret: true });
  assert.ok(!JSON.stringify(detail).includes('secret-value'));
  const events: LogStreamEvent[] = [];
  e.subscribeLogs(started.run.id, 0, { send: (ev) => events.push(ev), close() {}, backlog: () => 0, lastSentSeq: 0, pending: [], timer: null });
  assert.equal((await ended(e, started.run.id)).state, 'succeeded');
  assert.equal((await ended(e, failed.run.id)).exit?.code, 1);
  assert.ok(events.some((ev) => ev.type === 'end'));
  assert.equal(e.logPage(started.run.id, {}).runEnded, true);
  assert.equal(e.lastStats!.projects[p.id], undefined);
  for (let i = 0; i < 2; i++) await ended(e, e.startAction(p.id, 'build', { client: 'ui', agent: null }).run.id);
  assert.equal(e.actionRuns(p.id, 'build').length, 2);
  assert.throws(() => e.taskDetail(started.run.id), (err: unknown) => err instanceof HttpError && err.error.code === 'RUN_NOT_FOUND');
});

test('active task protects deletion; cancel timeout and force cancellation release logs', async () => {
  const { e, p, config } = setup();
  e.taskSimulation.durationMs = 5000;
  e.taskSimulation.hangOnCancel = true;
  const run = e.startAction(p.id, 'build', { client: 'ui', agent: null }).run;
  const taskRunning = (err: unknown) => err instanceof HttpError && err.error.code === 'TASK_RUNNING';
  assert.throws(() => e.remove(p.id), taskRunning);
  assert.throws(() => e.update(p.id, { ifRevision: 1, config: { ...config, actions: [] } }), taskRunning);
  e.cancelTask(run.id);
  await new Promise((resolve) => setTimeout(resolve, 1050));
  assert.equal(e.taskDetail(run.id).cancelTimedOut, true);
  e.cancelTask(run.id, true);
  const done = await ended(e, run.id);
  assert.equal(done.state, 'cancelled');
  assert.deepEqual(done.processes, []);
  assert.deepEqual(e.cancelTask(run.id), { ...e.actionRuns(p.id, 'build')[0] });
  e.remove(p.id);
});

test('timeout remains timed-out after forced cancellation', async () => {
  const { e, p, config } = setup();
  e.taskSimulation.durationMs = 5000;
  e.taskSimulation.hangOnCancel = true;
  e.update(p.id, { ifRevision: 1, config: { ...config, actions: [{ ...config.actions![0]!, timeoutSec: 1 }] } }, { client: 'ui', agent: null });
  const run = e.startAction(p.id, 'build', { client: 'ui', agent: null }).run;
  await new Promise((resolve) => setTimeout(resolve, 1050));
  assert.equal(e.taskDetail(run.id).state, 'cancelling');
  e.cancelTask(run.id, true);
  const done = await ended(e, run.id);
  assert.equal(done.state, 'timed-out');
  assert.equal(done.exit?.reason, 'timeout');
});

test('HTTP action routes return accepted/idempotent statuses and share log endpoints', async () => {
  const { createMockServer } = await import('../src/server.ts');
  const { e, p } = setup();
  e.taskSimulation.durationMs = 5000;
  const { server, issueLoginUrl } = createMockServer({ engine: e, port: 0, token: 'test-token', uiDir: null, log() {} });
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = (server.address() as import('node:net').AddressInfo).port;
  const call = (path: string, method = 'GET', body?: unknown) => fetch(`http://127.0.0.1:${port}/api/v1${path}`, { method, headers: { authorization: 'Bearer test-token', 'x-devpanel-client': 'ui', 'content-type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  try {
    assert.equal(new URL(issueLoginUrl()).port, String(port));
    const allowed = await fetch(`http://127.0.0.1:${port}/api/v1/daemon`, { headers: { authorization: 'Bearer test-token', origin: `http://localhost:${port}` } });
    assert.equal(allowed.status, 200);
    const denied = await fetch(`http://127.0.0.1:${port}/api/v1/daemon`, { headers: { authorization: 'Bearer test-token', origin: 'http://localhost:0' } });
    assert.equal(denied.status, 403);
    const endpoint = `/projects/${p.id}/actions/build/runs`;
    const response = await call(endpoint, 'POST');
    assert.equal(response.status, 202);
    const { run } = await response.json() as { run: { id: string } };
    assert.equal((await call(endpoint, 'POST')).status, 200);
    assert.equal((await call(`/task-runs/${run.id}`)).status, 200);
    const logs = await call(`/runs/${run.id}/logs`);
    assert.equal(logs.status, 200);
    assert.ok((await logs.text()).includes('开始任务'));
    assert.equal((await call(`/task-runs/${run.id}/cancel`, 'POST', { force: 'yes' })).status, 400);
    assert.equal((await call(`/task-runs/${run.id}/cancel`, 'POST')).status, 202);
    await ended(e, run.id);
    assert.equal((await call(`/task-runs/${run.id}/cancel`, 'POST')).status, 200);
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('lastRun retains only finished actions and log end retains the actual task summary', async () => {
  const { e, p } = setup();
  const first = e.startAction(p.id, 'build', { client: 'ui', agent: null }).run;
  assert.equal(e.view(e.getProj(p.id)).actions[0]!.lastRun, null);
  await ended(e, first.id);
  e.taskSimulation.durationMs = 1000;
  const next = e.startAction(p.id, 'build', { client: 'ui', agent: null }).run;
  assert.equal(e.view(e.getProj(p.id)).actions[0]!.lastRun!.id, first.id);
  assert.equal(e.view(e.getProj(p.id)).actions[0]!.currentRun!.id, next.id);
  const events: LogStreamEvent[] = [];
  e.subscribeLogs(first.id, 0, { send: ev => { events.push(ev); return true; }, close() {}, backlog: () => 0, lastSentSeq: 0, pending: [], timer: null });
  const end = events.find(ev => ev.type === 'end');
  assert.equal(end?.type === 'end' && 'kind' in end.run && end.run.kind, 'action');
  assert.throws(() => e.runDetail(next.id));
});
