import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import type { MavenRunRequest, ProjectConfig } from '@devpanel/contract';
import { Engine, DEFAULT_LIMITS } from '../src/engine.ts';
import { HttpError } from '../src/errors.ts';
import { demoMavenModel } from '../src/maven.ts';
import { seed } from '../src/seed.ts';
import { addVirtualDir, addVirtualFile } from '../src/validate.ts';
import { createMockServer } from '../src/server.ts';

const engines: Engine[] = [];
afterEach(() => engines.splice(0).forEach(e => e.stop()));
function setup() {
  const e = new Engine('/tmp/dp-maven-mock-test', { ...DEFAULT_LIMITS, taskRunsKept: 2 });
  engines.push(e);
  e.taskSimulation.durationMs = 40;
  e.taskSimulation.cancelDelayMs = 5;
  const root = '/virtual/maven';
  addVirtualDir(root); addVirtualFile(`${root}/mvnw`);
  const cfg: ProjectConfig = { schemaVersion: 1, name: 'Maven Demo', root,
    env: { JAVA_HOME: '/virtual/jdk', API_TOKEN: { secret: true, value: 'maven-secret' } },
    services: [{ id: 'backend', name: 'Backend', cwd: '.', command: ['node', 'server.js'] }],
    actions: [{ id: 'build', name: 'Build', cwd: '.', command: ['node', 'build.js'] }],
  };
  const p = e.register(cfg).body.project;
  e.seedMaven(p.id, demoMavenModel());
  return { e, p, cfg };
}
async function ended(e: Engine, id: string) {
  for (let i = 0; i < 100; i++) { const d = e.taskDetail(id); if (d.endedAt) return d; await new Promise(r => setTimeout(r, 10)); }
  throw new Error('Maven run did not finish');
}
const request: MavenRunRequest = { moduleId: 'backend', goals: ['clean', 'install'], profiles: ['local-db', '!integration'], skipTests: true, offline: true, alsoMake: true };

test('seed has five static modules, profile union, external parent and isolated POM error; reload does not run', async () => {
  const e = new Engine('/tmp/dp-maven-seed'); engines.push(e); seed(e);
  const p = e.getProj('p_ordersvc2a');
  const model = e.mavenModel(p.project.id);
  assert.deepEqual(model.modules.map(m => m.id), ['.', 'backend', 'contracts', 'external-parent', 'broken']);
  assert.deepEqual(model.profiles, ['dev', 'local-db', 'integration']);
  assert.equal(model.modules[3]!.parentOutside, true);
  assert.ok(model.modules[4]!.error);
  assert.equal(model.modules.filter(m => m.error).length, 1);
  assert.deepEqual(e.view(p).maven, { currentRun: null, lastRun: null });
  assert.deepEqual(e.mavenRuns(p.project.id), []);
  await new Promise(r => setTimeout(r, 5));
  assert.equal(e.mavenModel(p.project.id).scannedAt, model.scannedAt);
  assert.notEqual(e.mavenModel(p.project.id, true).scannedAt, model.scannedAt);
  assert.throws(() => e.mavenModel('p_mlapi22222'), (err: unknown) => err instanceof HttpError && err.status === 404 && err.error.code === 'MAVEN_UNAVAILABLE');
});

test('structured Maven command, project environment, single slot and action independence survive updates', async () => {
  const { e, p, cfg } = setup();
  const run = e.startMaven(p.id, request, { client: 'cli', agent: null }).run;
  assert.deepEqual(e.taskDetail(run.id).command, ['./mvnw', '-pl', 'backend', '-am', '-DskipTests', '-o', '-Plocal-db,!integration', 'clean', 'install']);
  assert.equal(e.taskDetail(run.id).cwd, cfg.root);
  assert.deepEqual(e.taskDetail(run.id).envKeys, ['JAVA_HOME', 'API_TOKEN']);
  assert.equal(run.kind, 'maven'); assert.equal(run.source, 'cli'); assert.equal(run.actionId, null);
  assert.equal(run.label, 'clean install · backend');
  assert.throws(() => e.startMaven(p.id, request, { client: 'ui', agent: null }), (err: unknown) => err instanceof HttpError && err.error.code === 'TASK_RUNNING' && err.error.details?.runId === run.id);
  const action = e.startAction(p.id, 'build', { client: 'ui', agent: null }).run;
  e.update(p.id, { ifRevision: p.revision, config: { ...cfg, name: 'Renamed' } });
  assert.equal(e.taskDetail(run.id).state, 'running');
  e.sampleAll(); assert.equal(Object.keys(e.lastStats!.projects[p.id]!.tasks).length, 2);
  assert.equal((await ended(e, run.id)).state, 'succeeded');
  await ended(e, action.id);
  const output = JSON.stringify(e.logPage(run.id, {}));
  for (const text of ['Reactor Build Order', 'maven-install-plugin', '[WARNING]', 'BUILD SUCCESS']) assert.ok(output.includes(text), text);
  assert.ok(!output.includes('maven-secret'));
  assert.equal(e.view(e.getProj(p.id)).maven?.currentRun, null);
  assert.equal(e.view(e.getProj(p.id)).maven?.lastRun?.id, run.id);
  assert.equal(e.lastStats!.projects[p.id], undefined);
});

test('strict structured input rejects invalid fields and options before creating runs', () => {
  const { e, p } = setup();
  for (const patch of [null, [], {}, { moduleId: '../outside', goals: ['install'] }, { moduleId: '.', goals: [] }, { moduleId: '.', goals: ['-f'] }, { moduleId: '.', goals: ['install;echo x'] }, { moduleId: '.', goals: ['install'], profiles: ['x,y'] }, { moduleId: '.', goals: ['install'], skipTests: 'yes' }, { moduleId: '.', goals: ['install'], command: ['sh'] }]) {
    assert.throws(() => e.startMaven(p.id, patch, { client: 'ui', agent: null }), (err: unknown) => err instanceof HttpError && err.status === 422 && err.error.code === 'MAVEN_INVALID' && typeof err.error.details?.field === 'string');
  }
  assert.equal(e.mavenRuns(p.id).length, 0);
});

test('executable selection, root arguments, failure output, cancellation and history retention', async () => {
  const { e, p, cfg } = setup();
  e.update(p.id, { ifRevision: p.revision, config: { ...cfg, maven: { executable: 'mvn' } } });
  assert.equal(e.mavenModel(p.id).executable, 'mvn');
  const failed = e.startMaven(p.id, { moduleId: '.', goals: ['install'], alsoMake: true }, { client: 'ui', agent: null }).run;
  assert.deepEqual(e.taskDetail(failed.id).command, ['mvn', 'install']);
  assert.equal((await ended(e, failed.id)).exit?.code, 1);
  assert.ok(JSON.stringify(e.logPage(failed.id, {})).includes('BUILD FAILURE'));
  e.taskSimulation.durationMs = 1000;
  const cancelled = e.startMaven(p.id, request, { client: 'ui', agent: null }).run;
  e.cancelTask(cancelled.id, true);
  assert.equal((await ended(e, cancelled.id)).state, 'cancelled');
  e.taskSimulation.durationMs = 40;
  await ended(e, e.startMaven(p.id, { moduleId: 'backend', goals: ['dependency:tree'] }, { client: 'ui', agent: null }).run.id);
  assert.equal(e.mavenRuns(p.id).length, 2);
  assert.throws(() => e.taskDetail(failed.id));
  e.update(p.id, { ifRevision: 2, config: { ...cfg, env: { PATH: '/missing' }, services: cfg.services.map(s => ({ ...s, env: { PATH: '/opt/homebrew/bin' } })), actions: cfg.actions!.map(a => ({ ...a, env: { PATH: '/opt/homebrew/bin' } })), maven: { executable: 'mvn' } } });
  assert.throws(() => e.mavenModel(p.id), (err: unknown) => err instanceof HttpError && err.error.code === 'COMMAND_NOT_FOUND');
  assert.equal(e.validate({ ...cfg, maven: { executable: 'invalid' } }).ok, false);
  addVirtualDir('/virtual/maven-without-wrapper');
  const fallback = e.register({ ...cfg, root: '/virtual/maven-without-wrapper' }).body.project;
  e.seedMaven(fallback.id, demoMavenModel());
  assert.equal(e.mavenModel(fallback.id).executable, 'mvn');
});

test('Maven model/reload/run/history HTTP routes use existing task and logs endpoints', async () => {
  const { e, p } = setup();
  e.taskSimulation.durationMs = 500;
  const { server } = createMockServer({ engine: e, port: 0, token: 'test', uiDir: null, log() {} });
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = (server.address() as import('node:net').AddressInfo).port;
  const call = (path: string, method = 'GET', body?: unknown) => fetch(`http://127.0.0.1:${port}/api/v1${path}`, { method, headers: { authorization: 'Bearer test', 'x-devpanel-client': 'ui', 'content-type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
  try {
    const base = `/projects/${p.id}/maven`;
    assert.equal((await call(`${base}?reload=1`)).status, 200);
    assert.equal((await call(`${base}?reload=yes`)).status, 400);
    const response = await call(`${base}/runs`, 'POST', request); assert.equal(response.status, 202);
    const { run } = await response.json() as { run: { id: string } };
    assert.equal((await call(`${base}/runs`, 'POST', request)).status, 409);
    assert.equal((await call(`/task-runs/${run.id}`)).status, 200);
    assert.equal((await call(`/runs/${run.id}/logs`)).status, 200);
    assert.equal((await call(`/task-runs/${run.id}/cancel`, 'POST', { force: true })).status, 202);
    await ended(e, run.id);
    assert.equal(((await (await call(`${base}/runs`)).json()) as unknown[]).length, 1);
  } finally { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); }
});

test('Maven lastRun remains the most recent finished run while a new run is active', async () => {
  const { e, p } = setup();
  const first = e.startMaven(p.id, { moduleId: '.', goals: ['install'] }, { client: 'ui', agent: null }).run;
  assert.equal(e.view(e.getProj(p.id)).maven!.lastRun, null);
  await ended(e, first.id);
  e.taskSimulation.durationMs = 1000;
  const next = e.startMaven(p.id, { moduleId: '.', goals: ['test'] }, { client: 'ui', agent: null }).run;
  assert.equal(e.view(e.getProj(p.id)).maven!.lastRun!.id, first.id);
  assert.equal(e.view(e.getProj(p.id)).maven!.currentRun!.id, next.id);
});

test('explicit virtual targets isolate Git state and Maven models and keep one project-wide build slot', async () => {
  const e = new Engine('/tmp/dp-target-mock-test'); engines.push(e); e.taskSimulation.durationMs = 40;
  const root = '/virtual/explicit-targets';
  for (const id of ['front', 'back']) {
    addVirtualDir(`${root}/${id}/.git`);
    addVirtualFile(`${root}/${id}/pom.xml`);
    addVirtualFile(`${root}/${id}/mvnw`);
  }
  const cfg: ProjectConfig = { schemaVersion: 1, name: 'Targets', root,
    services: [{ id: 'service', name: 'Service', cwd: '.', command: ['node', 'server.js'] }],
    repositories: ['front', 'back'].map(id => ({ id, name: id, path: id })),
    mavenProjects: ['front', 'back'].map(id => ({ id, name: id, path: id, executable: 'wrapper' })),
  };
  const p = e.register(cfg).body.project;
  assert.throws(() => e.git(p.id), (err: any) => err.error.code === 'BAD_REQUEST');
  assert.throws(() => e.git(p.id, 'missing'), (err: any) => err.error.code === 'BAD_REQUEST');
  e.seedGit(p.id, 'front'); e.seedGit(p.id, 'back');
  assert.notEqual(e.git(p.id, 'front'), e.git(p.id, 'back'));
  for (const id of ['front', 'back']) { const model = demoMavenModel(); model.modules[0]!.artifactId = id; e.seedMaven(p.id, model, id); }
  assert.throws(() => e.mavenModel(p.id), (err: any) => err.error.code === 'BAD_REQUEST');
  assert.equal(e.mavenModel(p.id, false, 'back').modules[0]!.artifactId, 'back');
  const run = e.startMaven(p.id, { ...request, mavenProjectId: 'back' }).run;
  assert.equal(e.taskDetail(run.id).cwd, root + '/back');
  assert.equal(run.maven?.mavenProjectId, 'back');
  assert.equal(e.view(e.getProj(p.id)).mavenProjects?.[1]?.currentRun?.id, run.id);
  assert.equal(e.view(e.getProj(p.id)).mavenProjects?.[0]?.currentRun, null);
  assert.throws(() => e.startMaven(p.id, { ...request, mavenProjectId: 'front' }), (err: any) => err.error.code === 'TASK_RUNNING');
  await ended(e, run.id);
  assert.equal(e.mavenRuns(p.id, 'front').length, 0);
  assert.equal(e.mavenRuns(p.id, 'back').length, 1);
});
