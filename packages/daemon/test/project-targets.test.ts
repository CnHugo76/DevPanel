import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, realpath, mkdir, writeFile, readFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import type { ProjectConfig } from '@devpanel/contract';
import { targetIssues, gitTarget, mavenTarget } from '../src/project-targets.ts';
import { startServer } from '../src/server.ts';
import { cleanupTaskServer } from './helpers/cleanup.ts';
import { sleep } from '../src/storage.ts';
const exec = promisify(execFile);
const cli = resolve(import.meta.dirname, '../../cli/src/main.ts');
const badId = (e: any) => e.error?.code === 'BAD_REQUEST';

test('explicit targets reject ambiguity, duplicates, traversal and symlink escape; legacy remains compatible', async t => {
  const root = await mkdtemp(join(tmpdir(), 'dp-target-validation-'));
  const outside = await mkdtemp(join(tmpdir(), 'dp-target-outside-'));
  t.after(async () => { await rm(root, { recursive: true, force: true }); await rm(outside, { recursive: true, force: true }); });
  await mkdir(join(root, 'a/.git'), { recursive: true });
  await writeFile(join(root, 'a/pom.xml'), '<project/>');
  await symlink(outside, join(root, 'escape'));
  await symlink(join(root, 'a'), join(root, 'alias'));
  const config: ProjectConfig = { schemaVersion: 1, name: 'Targets', root, services: [{ id: "service", name: "Service", cwd: ".", command: ["/bin/echo", "fixture"] }] };
  assert.equal(gitTarget(config), root);
  assert.equal(mavenTarget(config).config.root, root);
  assert.throws(() => gitTarget(config, 'unknown'), badId);
  const targets = ['a', 'alias'].map((path, i) => ({ id: 'repo-' + i, name: path, path }));
  assert.ok(targetIssues({ ...config, repositories: targets }).some(i => i.message.includes('重复')));
  for (const path of ['../outside', root, 'escape', '${target}', 'a/../a']) {
    assert.ok(targetIssues({ ...config, repositories: [{ id: 'a', name: 'A', path }] }).length, path);
  }
  config.repositories = [{ id: 'a', name: 'A', path: 'a' }];
  assert.equal(gitTarget(config), await realpath(join(root, 'a')));
  assert.throws(() => gitTarget(config, 'missing'), badId);
  assert.throws(() => gitTarget({ ...config, repositories: [] }), badId);
  assert.throws(() => gitTarget({ ...config, repositories: targets }), badId);
  assert.deepEqual(targetIssues({ ...config, mavenProjects: [{ id: 'build', name: 'Build', path: 'a' }] }), []);
});

test('HTTP selectors isolate identically named files across sibling repositories, including writes', async t => {
  const base = await mkdtemp(join(tmpdir(), 'dp-target-git-')), root = join(base, 'workspace');
  for (const name of ['front', 'back']) {
    const cwd = join(root, name); await mkdir(cwd, { recursive: true });
    const env = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
    await exec('/usr/bin/git', ['init', '-b', 'main'], { cwd, env });
    await exec('/usr/bin/git', ['config', 'user.name', 'Fixture'], { cwd, env });
    await exec('/usr/bin/git', ['config', 'user.email', 'fixture@example.invalid'], { cwd, env });
    await exec('/usr/bin/git', ['config', 'commit.gpgsign', 'false'], { cwd, env });
    await writeFile(join(cwd, 'same.txt'), name + '\n');
  }
  const server = await startServer(join(base, 'home'), 0);
  t.after(async () => { await server.close(); await rm(base, { recursive: true, force: true }); });
  const config: ProjectConfig = { schemaVersion: 1, name: 'Workspace', root, services: [{ id: "service", name: "Service", cwd: ".", command: ["/bin/echo", "fixture"] }], repositories: ['front', 'back'].map(id => ({ id, name: id, path: id })) };
  const p = server.manager.register(config).project;
  assert.equal(server.manager.runs.size, 0);
  const { token } = JSON.parse(await readFile(join(base, 'home/daemon.json'), 'utf8'));
  const api = (path: string, method = 'GET', body?: unknown, client = 'ui') => fetch(`http://127.0.0.1:${server.httpPort}/api/v1/projects/${p.id}/git/${path}`, { method, headers: { Authorization: `Bearer ${token}`, 'X-DevPanel-Client': client, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
  assert.equal((await api('status')).status, 400);
  assert.equal((await api('status?repositoryId=missing')).status, 400);
  assert.equal((await api('stage?repositoryId=front', 'POST', { paths: ['same.txt'] }, 'cli')).status, 403);
  assert.equal((await api('stage?repositoryId=front', 'POST', { paths: ['same.txt'] })).status, 200);
  const back = await (await api('status?repositoryId=back')).json() as any;
  assert.equal(back.entries[0].untracked, true);
  assert.equal(back.entries[0].index, null);
  const diff = await (await api('diff?repositoryId=front&path=same.txt&staged=true')).json() as any;
  assert.ok(diff.hunks.flatMap((h: any) => h.lines).some((l: any) => l.text === 'front'));
  assert.equal((await api('commit?repositoryId=front', 'POST', { message: 'front only', expectedHead: null })).status, 200);
  assert.equal((await (await api('status?repositoryId=front')).json() as any).entries.length, 0);
  assert.equal((await (await api('status?repositoryId=back')).json() as any).repo.headSha, null);
  assert.equal((await api('stash?repositoryId=back', 'POST', {})).status, 422); // unborn back unaffected by front commit
});

test('nested Maven targets use their own wrapper, cwd, models, CLI selector and recorded target ID', async t => {
  const root = await mkdtemp(join(tmpdir(), 'dp-target-maven-'));
  for (const id of ['alpha', 'beta']) {
    await mkdir(join(root, id));
    await writeFile(join(root, id, 'pom.xml'), `<project><artifactId>${id}</artifactId></project>`);
    await writeFile(join(root, id, 'mvnw'), `#!${process.execPath}\nconsole.log(process.cwd()); console.log(process.env.FIXTURE_TARGET); setTimeout(()=>{},250);`, { mode: 0o755 });
  }
  const server = await startServer(join(root, 'home'), 0), m = server.manager;
  t.after(() => cleanupTaskServer(server, root));
  const p = m.register({ schemaVersion: 1, name: 'Nested Maven', root, env: { FIXTURE_TARGET: 'preserved' }, services: [{ id: "service", name: "Service", cwd: ".", command: ["/bin/echo", "fixture"] }], mavenProjects: ['alpha', 'beta'].map(id => ({ id, name: id, path: id, executable: 'wrapper' })) }).project;
  assert.equal(m.runs.size, 0);
  await assert.rejects(m.mavenModel(p.id), badId);
  await assert.rejects(m.mavenModel(p.id, false, 'missing'), badId);
  assert.equal((await m.mavenModel(p.id, false, 'alpha')).modules[0]?.artifactId, 'alpha');
  const command = (...args: string[]) => exec(process.execPath, [cli, ...args], { env: { ...process.env, DEVPANEL_HOME: join(root, 'home') } });
  const beta = JSON.parse((await command('maven', 'modules', p.id, '--maven-project', 'beta', '--json')).stdout);
  assert.equal(beta.modules[0].artifactId, 'beta');
  const started = await m.startMaven(p.id, { mavenProjectId: 'alpha', moduleId: '.', goals: ['verify'] }, { client: 'ui', agent: null });
  assert.equal(m.taskDetail(started.run.id).cwd, await realpath(join(root, 'alpha')));
  assert.equal(started.run.maven?.mavenProjectId, 'alpha');
  assert.equal(m.view(p.id).mavenProjects?.[0]?.currentRun?.id, started.run.id);
  assert.equal(m.view(p.id).mavenProjects?.[1]?.currentRun, null);
  await assert.rejects(m.startMaven(p.id, { mavenProjectId: 'beta', moduleId: '.', goals: ['verify'] }), (e: any) => e.error.code === 'TASK_RUNNING');
  for (let i = 0; i < 200 && !m.taskDetail(started.run.id).endedAt; i++) { await m.refresh(); await sleep(20); }
  assert.equal(m.taskDetail(started.run.id).state, 'succeeded');
  assert.ok(JSON.stringify(m.logs.page(started.run.id, new URLSearchParams(), true)).includes('preserved'));
  const result = JSON.parse((await command('maven', 'run', p.id, '--maven-project', 'beta', 'verify', '--json', '--follow')).stdout);
  assert.equal(result.maven.mavenProjectId, 'beta');
  assert.equal(result.state, 'succeeded');
});
