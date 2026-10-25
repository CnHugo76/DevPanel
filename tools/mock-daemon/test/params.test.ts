import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { after, describe, it } from 'node:test';
import type { AddressInfo } from 'node:net';
import type { Operation, ParamConfig, Project, ProjectConfig, ServiceConfig } from '@devpanel/contract';
import { DEFAULT_LIMITS, Engine } from '../src/engine.ts';
import { HttpError } from '../src/errors.ts';
import { MASK, inlineParam, shellQuote, shellScriptIndex, substituteService, tokenize } from '../src/params.ts';
import { seed } from '../src/seed.ts';
import { createMockServer } from '../src/server.ts';
import { addVirtualDir, addVirtualFile } from '../src/validate.ts';

const engines: Engine[] = [];
function mk(): Engine {
  const e = new Engine('/tmp/devpanel-mock-test', { ...DEFAULT_LIMITS, startGraceMs: 50 });
  e.sim.listenFailRate = 0;
  engines.push(e);
  return e;
}
after(() => engines.forEach((e) => e.stop()));

addVirtualDir('/virtual/params/a');
addVirtualDir('/virtual/params/b');
addVirtualFile('/virtual/params/a/mvnw');

const p = (x: Partial<ParamConfig> & Pick<ParamConfig, 'key' | 'type'>): ParamConfig => ({ label: x.key, ...x }) as ParamConfig;

function cfg(params: ParamConfig[], services: ServiceConfig[], over: Partial<ProjectConfig> = {}): ProjectConfig {
  return { schemaVersion: 1, name: 'params-demo', root: '/virtual/params', params, services, ...over };
}

const svc = (id: string, command: string[], env?: ServiceConfig['env']): ServiceConfig => ({
  id,
  name: id,
  cwd: id === 'b' ? 'b' : 'a',
  command,
  ...(env ? { env } : {}),
  stopTimeoutSec: 2,
});

function httpErr(code: string, status?: number) {
  return (err: unknown) => err instanceof HttpError && err.error.code === code && (status === undefined || err.status === status);
}

async function finished(e: Engine, op: Operation): Promise<Operation> {
  return e.waitOperation(op.id, 10_000);
}

const NASTY = `it's a $HOME; rm -rf / && echo "x" \`id\` \${y}`;

describe('placeholders and substitution', () => {
  it('tokenizes ${key}, keeps $${ and non-key braces literal', () => {
    const t = tokenize('a${x}b$${y}c${a:-b}${');
    assert.deepEqual(
      t.map((x) => (x.kind === 'ref' ? `<${x.key}>` : x.text)),
      ['a', '<x>', 'b${y}c${a:-b}${'],
    );
  });

  it('detects shell invocations per contract', () => {
    assert.equal(shellScriptIndex(['zsh', '-lc', 'x']), 2);
    assert.equal(shellScriptIndex(['/bin/bash', '-c', 'x', 'arg0']), 2);
    assert.equal(shellScriptIndex(['sh', '-e', '-c', 'x']), 3);
    assert.equal(shellScriptIndex(['node', '-c', 'x']), -1);
    assert.equal(shellScriptIndex(['zsh', 'script.zsh']), -1);
  });

  it('formats numbers / booleans, keeps one argv element, escapes inside zsh -lc script as one literal', () => {
    const c = cfg(
      [
        p({ key: 'msg', type: 'string', value: NASTY }),
        p({ key: 'port', type: 'number', value: 8081 }),
        p({ key: 'ratio', type: 'number', value: 0.5 }),
        p({ key: 'debug', type: 'boolean', value: false }),
        p({ key: 'tok', type: 'string', value: 'sekret', secret: true }),
      ],
      [
        svc('a', ['zsh', '-lc', 'printf "[%s]" ${msg}; echo $${HOME} ${port}', '${msg}'], { A: 'p=${port} d=${debug} r=${ratio}', T: '${tok}' }),
        svc('b', ['node', 'srv.js', '--name=${msg}', '--port', '${port}', '--token=${tok}', '$${literal}']),
      ],
    );
    const a = substituteService(c, c.services[0]!);
    assert.equal(a.command.length, 4);
    assert.equal(a.command[2], `printf "[%s]" ${shellQuote(NASTY)}; echo \${HOME} '8081'`);
    assert.equal(a.command[3], NASTY, 'positional args after the script are plain argv');
    assert.equal(a.env.A, 'p=8081 d=false r=0.5');
    assert.equal(a.env.T, 'sekret');
    assert.equal(a.displayEnv.T, MASK);
    assert.deepEqual(a.params, { msg: NASTY, port: 8081, ratio: 0.5, debug: false, tok: { secret: true } });

    const b = substituteService(c, c.services[1]!);
    assert.deepEqual(b.command, ['node', 'srv.js', `--name=${NASTY}`, '--port', '8081', '--token=sekret', '${literal}']);
    assert.deepEqual(b.display, ['node', 'srv.js', `--name=${NASTY}`, '--port', '8081', `--token=${MASK}`, '${literal}']);

    // The quoted value really is one literal word for zsh (and sh).
    for (const shell of ['/bin/zsh', '/bin/sh']) {
      if (!existsSync(shell)) continue;
      const out = execFileSync(shell, ['-c', `printf "[%s]" ${shellQuote(NASTY)}`], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin' } });
      assert.equal(out, `[${NASTY}]`, shell);
    }
  });

  it('RunDetail.command is the substituted argv with secrets masked; first sys line shows it', async () => {
    const e = mk();
    const c = cfg(
      [p({ key: 'profile', type: 'enum', value: 'dev', choices: [{ value: 'dev' }, { value: 'test' }] }), p({ key: 'tok', type: 'string', value: 's3cr3t', secret: true })],
      [svc('a', ['node', 'server.js', '--profile=${profile}', '--token=${tok}'])],
    );
    const { body } = e.register(c, { client: 'cli', agent: null });
    const op = await finished(e, e.submit({ projectId: body.project.id, action: 'start' }, { client: 'ui', agent: null }));
    const runId = op.results[0]!.runId!;
    const d = e.runDetail(runId);
    assert.deepEqual(d.command, ['node', 'server.js', '--profile=dev', `--token=${MASK}`]);
    assert.deepEqual(d.params, { profile: 'dev', tok: { secret: true } });
    const first = e.logPage(runId, { limit: 5 }).lines[0]!;
    assert.equal(first.stream, 'sys');
    assert.match(first.text, /node server\.js --profile=dev --token=••••$/);
    const all = JSON.stringify([e.logPage(runId, {}), d, e.maskedProject(e.getProj(body.project.id))]);
    assert.ok(!all.includes('s3cr3t'), 'secret value never leaves the engine');
  });
});

describe('param validation', () => {
  const base = (params: unknown[], services?: ServiceConfig[]) =>
    ({ schemaVersion: 1, name: 'v', root: '/virtual/params', params, services: services ?? [svc('a', ['node', 'x.js', '${port}'])] }) as unknown as ProjectConfig;
  const codes = (e: Engine, c: ProjectConfig) => e.validate(c).issues.map((i) => `${i.severity}:${i.code}:${i.path}`);

  it('PARAM_UNKNOWN for references to missing keys (command and non-secret env), secret env is literal', () => {
    const e = mk();
    const issues = codes(
      e,
      base([p({ key: 'port', type: 'number', value: 1 })], [svc('a', ['node', '${nope}', '${port}'], { X: '${other}', S: { secret: true, value: '${ignored}' } })]),
    );
    assert.ok(issues.includes('error:PARAM_UNKNOWN:services[0].command[1]'));
    assert.ok(issues.includes('error:PARAM_UNKNOWN:services[0].env.X'));
    assert.ok(!issues.some((i) => i.endsWith('env.S')));
  });

  it('PARAM_INVALID for key format, duplicates, type, choices and min/max', () => {
    const e = mk();
    const issues = codes(
      e,
      base([
        p({ key: 'port', type: 'number', value: 80, min: 1024, max: 65535 }),
        p({ key: '9bad', type: 'string', value: 'x' }),
        p({ key: 'port', type: 'number', value: 2000 }),
        p({ key: 'mode', type: 'enum', value: 'nope', choices: [{ value: 'a' }] }),
        p({ key: 'flag', type: 'boolean', value: 'yes' as unknown as boolean }),
        p({ key: 'empty', type: 'enum', value: 'a', choices: [] }),
        p({ key: 'str', type: 'string' }),
      ]),
    );
    for (const want of [
      'error:PARAM_INVALID:params[0].value',
      'error:PARAM_INVALID:params[1].key',
      'error:PARAM_INVALID:params[2].key',
      'error:PARAM_INVALID:params[3].value',
      'error:PARAM_INVALID:params[4].value',
      'error:PARAM_INVALID:params[5].choices',
      'error:PARAM_INVALID:params[6].value',
    ]) {
      assert.ok(issues.includes(want), `${want} in ${issues.join(', ')}`);
    }
  });

  it('WARN_PARAM_UNUSED is a non-blocking warning; standalone secret without value is fine but register rejects it', () => {
    const e = mk();
    const c = base([p({ key: 'port', type: 'number', value: 3000 }), p({ key: 'unused', type: 'string', value: 'x' }), p({ key: 'tok', type: 'string', secret: true })], [
      svc('a', ['node', 'x.js', '${port}'], { API_TOKEN: '${tok}' }),
    ]);
    const res = e.validate(c);
    assert.equal(res.ok, true);
    assert.deepEqual(
      res.issues.map((i) => `${i.severity}:${i.code}:${i.path}`),
      ['warning:WARN_PARAM_UNUSED:params[1]'],
      'no WARN_SECRET_LIKE_PLAIN for an env value that only pulls in secret params',
    );
    assert.throws(() => e.register(c, { client: 'cli', agent: null }), httpErr('CONFIG_INVALID', 422));
  });
});

describe('setter and user-value protection', () => {
  const host = (value: string) =>
    p({ key: 'host', type: 'enum', value, choices: [{ value: '127.0.0.1', label: '仅本机' }, { value: '0.0.0.0', label: '局域网' }] });
  const services = [svc('a', ['node', 'x.js', '--host=${host}', '--port=${port}'])];

  it('records setBy from the client, keeps user values on PUT unless overrideUserValues, lists keptUserValues', () => {
    const e = mk();
    const c = cfg([host('127.0.0.1'), p({ key: 'port', type: 'number', value: 8081 })], services);
    const { body } = e.register(c, { client: 'cli', agent: null });
    const id = body.project.id;
    assert.equal(body.project.config.params![0]!.setBy, 'agent');
    assert.equal(body.project.config.params![0]!.describedBy, 'agent');
    assert.deepEqual(body.project.config.params![0]!.usedBy, [{ serviceId: 'a', where: 'command', index: 2 }]);

    const afterUser = e.patchParam(id, 'host', { ifRevision: 1, value: '0.0.0.0' }, { client: 'ui', agent: null });
    const hp = afterUser.config.params!.find((x) => x.key === 'host')!;
    assert.equal(hp.setBy, 'user');
    assert.equal(hp.describedBy, 'agent');
    assert.equal(afterUser.revision, 2);

    // Agent pushes its stale config (host 127.0.0.1) and a new port: port changes, host is kept.
    const upd = e.update(id, { ifRevision: 2, config: cfg([host('127.0.0.1'), p({ key: 'port', type: 'number', value: 9090 })], services) }, { client: 'cli', agent: null });
    assert.deepEqual(upd.keptUserValues, ['host']);
    assert.equal(upd.config.params!.find((x) => x.key === 'host')!.value, '0.0.0.0');
    assert.equal(upd.config.params!.find((x) => x.key === 'port')!.value, 9090);
    assert.equal(upd.config.params!.find((x) => x.key === 'host')!.setBy, 'user');

    // Re-registration with the stale value is idempotent (user value wins in the comparison).
    const again = e.register(cfg([host('127.0.0.1'), p({ key: 'port', type: 'number', value: 9090 })], services), { client: 'cli', agent: null });
    assert.equal(again.status, 200);
    assert.equal(again.body.created, false);

    // Explicit override.
    const forced = e.update(id, { ifRevision: upd.revision, overrideUserValues: true, config: cfg([host('127.0.0.1'), p({ key: 'port', type: 'number', value: 9090 })], services) }, { client: 'cli', agent: null });
    assert.equal(forced.keptUserValues, undefined);
    const fh = forced.config.params!.find((x) => x.key === 'host')!;
    assert.equal(fh.value, '127.0.0.1');
    assert.equal(fh.setBy, 'agent');
  });

  it('a kept user value that no longer fits the new definition is refused, not silently overwritten', () => {
    const e = mk();
    const { body } = e.register(cfg([host('127.0.0.1'), p({ key: 'port', type: 'number', value: 8081 })], services), { client: 'cli', agent: null });
    e.patchParam(body.project.id, 'port', { ifRevision: 1, value: 2000 }, { client: 'ui', agent: null });
    assert.throws(
      () => e.update(body.project.id, { ifRevision: 2, config: cfg([host('127.0.0.1'), p({ key: 'port', type: 'number', value: 8081, min: 3000 })], services) }, { client: 'cli', agent: null }),
      httpErr('CONFIG_INVALID', 422),
    );
  });

  it('label / description edits set describedBy without touching setBy', () => {
    const e = mk();
    const { body } = e.register(cfg([host('127.0.0.1'), p({ key: 'port', type: 'number', value: 8081 })], services), { client: 'cli', agent: null });
    const r = e.patchParam(body.project.id, 'port', { ifRevision: 1, label: '后端端口', description: '改过' }, { client: 'ui', agent: null });
    const pp = r.config.params!.find((x) => x.key === 'port')!;
    assert.equal(pp.describedBy, 'user');
    assert.equal(pp.setBy, 'agent');
    assert.equal(pp.label, '后端端口');
    assert.throws(() => e.patchParam(body.project.id, 'port', { ifRevision: 1, value: 1 }, { client: 'ui', agent: null }), httpErr('REVISION_MISMATCH', 409));
    assert.throws(() => e.patchParam(body.project.id, 'nope', { ifRevision: 2, value: 1 }, { client: 'ui', agent: null }), httpErr('PARAM_UNKNOWN', 404));
    assert.throws(
      () => e.patchParam(body.project.id, 'host', { ifRevision: 2, value: '10.0.0.1' }, { client: 'ui', agent: null }),
      (err: unknown) => httpErr('CONFIG_INVALID', 422)(err) && JSON.stringify((err as HttpError).error.details).includes('PARAM_INVALID'),
    );
    assert.throws(
      () => e.addParam(body.project.id, { ifRevision: 2, param: p({ key: 'port', type: 'number', value: 1 }) }, { client: 'ui', agent: null }),
      httpErr('CONFIG_CONFLICT', 409),
    );
    const added = e.addParam(body.project.id, { ifRevision: 2, param: p({ key: 'extra', type: 'string', value: 'x' }) }, { client: 'ui', agent: null });
    assert.equal(added.config.params!.at(-1)!.setBy, 'user');
    assert.deepEqual(added.config.params!.at(-1)!.usedBy, []);
  });
});

describe('configChangedSinceStart with params', () => {
  it('marks only services that reference the changed param, clears when restored', async () => {
    const e = mk();
    const c = cfg(
      [p({ key: 'apiPort', type: 'number', value: 8081 }), p({ key: 'webPort', type: 'number', value: 3000 }), p({ key: 'shared', type: 'string', value: 'x' })],
      [svc('a', ['node', 'api.js', '--port', '${apiPort}'], { S: '${shared}' }), svc('b', ['node', 'web.js', '--port', '${webPort}'], { API: 'http://localhost:${apiPort}' })],
    );
    const id = e.register(c, { client: 'cli', agent: null }).body.project.id;
    await finished(e, e.submit({ projectId: id, action: 'start' }, { client: 'ui', agent: null }));
    const changed = () => Object.fromEntries(e.view(e.getProj(id)).services.map((s) => [s.id, s.configChangedSinceStart]));
    assert.deepEqual(changed(), { a: false, b: false });

    e.patchParam(id, 'webPort', { ifRevision: 1, value: 3001 }, { client: 'ui', agent: null });
    assert.deepEqual(changed(), { a: false, b: true });
    e.patchParam(id, 'webPort', { ifRevision: 2, value: 3000 }, { client: 'ui', agent: null });
    assert.deepEqual(changed(), { a: false, b: false });
    e.patchParam(id, 'apiPort', { ifRevision: 3, value: 9000 }, { client: 'ui', agent: null });
    assert.deepEqual(changed(), { a: true, b: true }, 'apiPort is used by a (command) and b (env)');
    e.patchParam(id, 'apiPort', { ifRevision: 4, value: 8081, description: 'only text changes after this' }, { client: 'ui', agent: null });
    e.patchParam(id, 'apiPort', { ifRevision: 5, label: '后端端口' }, { client: 'ui', agent: null });
    assert.deepEqual(changed(), { a: false, b: false }, 'description edits do not change the effective config');
    await finished(e, e.submit({ projectId: id, action: 'stop' }, { client: 'ui', agent: null }));
  });
});

describe('deleting params', () => {
  const mkProj = (e: Engine) =>
    e.register(cfg(
        [
          p({ key: 'unused', type: 'string', value: 'x' }),
          p({ key: 'msg', type: 'string', value: "it's ${HOME}" }),
          p({ key: 'cmdTok', type: 'string', value: 'c-secret', secret: true }),
          p({ key: 'envTok', type: 'string', value: 'e-secret', secret: true }),
        ],
        [
          svc('a', ['zsh', '-lc', 'exec node server.js --msg ${msg}', '${cmdTok}'], { GREETING: 'hi ${msg}', AUTH: 'Bearer ${envTok}' }),
          svc('b', ['node', 'b.js', '--msg=${msg}']),
        ],
      ), { client: 'cli', agent: null }
    ).body.project;

  it('deletes an unreferenced param directly', () => {
    const e = mk();
    const proj = mkProj(e);
    const r = e.deleteParam(proj.id, 'unused', { ifRevision: 1, inline: false });
    assert.equal(r.revision, 2);
    assert.ok(!r.config.params!.some((x) => x.key === 'unused'));
    assert.throws(() => e.deleteParam(proj.id, 'unused', { ifRevision: 2, inline: false }), httpErr('PARAM_UNKNOWN', 404));
    assert.throws(() => e.deleteParam(proj.id, 'msg', { ifRevision: 1, inline: true }), httpErr('REVISION_MISMATCH', 409));
  });

  it('refuses a referenced param without inline; inline writes the value back so the effective command is unchanged', async () => {
    const e = mk();
    const proj = mkProj(e);
    assert.throws(
      () => e.deleteParam(proj.id, 'msg', { ifRevision: 1, inline: false }),
      (err: unknown) => httpErr('PARAM_IN_USE', 409)(err) && Array.isArray((err as HttpError).error.details?.usedBy) && ((err as HttpError).error.details!.usedBy as unknown[]).length === 3,
    );
    await finished(e, e.submit({ projectId: proj.id, action: 'start', serviceIds: ['b'] }, { client: 'ui', agent: null }));
    const before = substituteService(e.getProj(proj.id).project.config, e.getProj(proj.id).project.config.services[0]!);
    const r = e.deleteParam(proj.id, 'msg', { ifRevision: 1, inline: true });
    const a = r.config.services[0]!;
    assert.equal(a.command[2], `exec node server.js --msg 'it'\\''s $\${HOME}'`, 'quoted for the shell, "${" escaped as "$${"');
    assert.equal(a.env!.GREETING, 'hi it\'s $${HOME}');
    assert.deepEqual(r.config.services[1]!.command, ['node', 'b.js', '--msg=it\'s $${HOME}']);
    const afterSub = substituteService(e.getProj(proj.id).project.config, e.getProj(proj.id).project.config.services[0]!);
    assert.deepEqual(afterSub.command, before.command);
    assert.equal(afterSub.env.GREETING, before.env.GREETING);
    assert.equal(e.view(e.getProj(proj.id)).services[1]!.configChangedSinceStart, false, 'running b keeps the same effective command');
    await finished(e, e.submit({ projectId: proj.id, action: 'stop' }, { client: 'ui', agent: null }));
  });

  it('refuses to inline a secret referenced by a command; a secret referenced by env becomes a secret env value', () => {
    const e = mk();
    const proj = mkProj(e);
    assert.throws(
      () => e.deleteParam(proj.id, 'cmdTok', { ifRevision: 1, inline: true }),
      (err: unknown) => httpErr('PARAM_IN_USE', 409)(err) && (err as HttpError).error.details?.reason === 'secret',
    );
    const r = e.deleteParam(proj.id, 'envTok', { ifRevision: 1, inline: true });
    assert.deepEqual(r.config.services[0]!.env!.AUTH, { secret: true });
    const stored = e.getProj(proj.id).project.config.services[0]!.env!.AUTH;
    assert.deepEqual(stored, { secret: true, value: 'Bearer e-secret' });
    assert.ok(!JSON.stringify(r).includes('e-secret'));
  });

  it('pure inlineParam leaves other placeholders and literals untouched', () => {
    const c = cfg([p({ key: 'a', type: 'number', value: 1 }), p({ key: 'b', type: 'boolean', value: true })], [svc('a', ['x', '${a}-${b}-$${a}'])]);
    assert.deepEqual(inlineParam(c, 'a').services[0]!.command, ['x', '1-${b}-$${a}']);
  });
});

describe('listening ports (v1.1-B)', () => {
  it('null until bound, then the ports (matching param values), gone after stop', async () => {
    const e = mk();
    e.sim.listenDelayMs = 300;
    const id = e.register(cfg(
        [
          p({ key: 'apiPort', type: 'number', value: 8123 }),
          p({ key: 'host', type: 'enum', value: '127.0.0.1', choices: [{ value: '127.0.0.1' }, { value: '0.0.0.0' }] }),
        ],
        [
          svc('a', ['./mvnw', 'spring-boot:run', '-Dspring-boot.run.arguments=--server.port=${apiPort} --server.address=${host}']),
          svc('b', ['uv', 'run', 'uvicorn', 'app:app', '--port', '9001']),
        ],
      ), { client: 'cli', agent: null }
    ).body.project.id;
    await finished(e, e.submit({ projectId: id, action: 'start' }, { client: 'ui', agent: null }));
    const listening = () => {
      e.sampleAll();
      const s = e.lastStats!.projects[id]?.services ?? {};
      return Object.fromEntries(Object.entries(s).map(([k, v]) => [k, v.listening]));
    };
    assert.deepEqual(listening(), { a: null, b: null });
    await new Promise((r) => setTimeout(r, 350));
    const l = listening();
    assert.deepEqual(
      l.a!.map((x) => [x.port, x.address, x.family, x.scope]),
      [
        [8123, '127.0.0.1', 'ipv4', 'loopback'],
        [35729, '0.0.0.0', 'ipv4', 'all'],
      ],
    );
    assert.deepEqual(l.b!.map((x) => [x.port, x.address, x.scope]), [[9001, '127.0.0.1', 'loopback']]);
    const pids = e.runDetail(e.view(e.getProj(id)).services[0]!.currentRun!.id).processes.map((x) => x.pid);
    assert.ok(pids.includes(l.a![0]!.pid), 'held by a managed process of the run');

    await finished(e, e.submit({ projectId: id, action: 'stop', serviceIds: ['a'] }, { client: 'ui', agent: null }));
    const after = listening();
    assert.equal(after.a, undefined, 'stopped service is no longer in stats');
    assert.ok(Array.isArray(after.b));
    await finished(e, e.submit({ projectId: id, action: 'stop' }, { client: 'ui', agent: null }));
  });
});

describe('seed data', () => {
  it('seeded params validate, are all referenced, and host shows "changed since start" only on the backend', () => {
    const e = mk();
    seed(e);
    for (const proj of e.projects) {
      const issues = e.validate(proj.project.config).issues.filter((i) => i.code.startsWith('PARAM_') || i.code === 'WARN_PARAM_UNUSED');
      assert.deepEqual(issues, [], proj.project.config.name);
    }
    const order = e.getProj('p_ordersvc2a');
    const params = e.maskedProject(order).config.params!;
    assert.deepEqual(params.map((x) => [x.key, x.setBy]), [
      ['profile', 'agent'],
      ['apiPort', 'agent'],
      ['host', 'user'],
    ]);
    assert.deepEqual(e.view(order).services.map((s) => [s.id, s.configChangedSinceStart]), [
      ['backend', true],
      ['frontend', false],
    ]);
    const run = e.runDetail(e.view(order).services[0]!.currentRun!.id);
    assert.equal(run.params.host, '127.0.0.1');
    const ml = e.maskedProject(e.getProj('p_mlapi22222')).config.params!;
    assert.equal(ml.find((x) => x.key === 'hfToken')!.value, undefined);
    assert.equal(ml.find((x) => x.key === 'hfToken')!.secret, true);
    e.stop();
  });
});

describe('HTTP routes', () => {
  it('POST / PATCH / DELETE params map X-DevPanel-Client to setBy and emit project.upsert', async () => {
    const e = mk();
    const token = 't';
    const { server } = createMockServer({ engine: e, port: 0, token, uiDir: null, log: () => {} });
    await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    const port = (server.address() as AddressInfo).port;
    const upserts: string[] = [];
    e.listeners.add((ev) => {
      if (ev.type === 'project.upsert') upserts.push(ev.project.id);
    });
    const call = async (method: string, path: string, client: string, body?: unknown) => {
      const res = await fetch(`http://127.0.0.1:${port}/api/v1${path}`, {
        method,
        headers: { authorization: `Bearer ${token}`, 'x-devpanel-client': client, 'content-type': 'application/json' },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
      return { status: res.status, json: (await res.json()) as Project & { error?: { code: string } } };
    };
    try {
      const reg = await call('POST', '/projects', 'cli', cfg([p({ key: 'port', type: 'number', value: 1 })], [svc('a', ['node', 'x.js', '${port}'])]));
      const id = (reg.json as unknown as { project: Project }).project.id;
      const add = await call('POST', `/projects/${id}/params`, 'ui', { ifRevision: 1, param: p({ key: 'flag', type: 'boolean', value: true }) });
      assert.equal(add.status, 200);
      assert.equal(add.json.config.params![1]!.setBy, 'user');
      const patch = await call('PATCH', `/projects/${id}/params/port`, 'cli', { ifRevision: 2, value: 2 });
      assert.equal(patch.json.config.params![0]!.setBy, 'agent');
      const inUse = await call('DELETE', `/projects/${id}/params/port?ifRevision=3`, 'ui');
      assert.equal(inUse.status, 409);
      assert.equal(inUse.json.error!.code, 'PARAM_IN_USE');
      const del = await call('DELETE', `/projects/${id}/params/port?ifRevision=3&inline=true`, 'ui');
      assert.equal(del.status, 200);
      assert.deepEqual(del.json.config.services[0]!.command, ['node', 'x.js', '2']);
      assert.ok(upserts.filter((x) => x === id).length >= 4);
    } finally {
      server.closeAllConnections();
      await new Promise((r) => server.close(r));
    }
  });
});
