import assert from 'node:assert/strict';
import { after, describe, it } from 'node:test';
import type { Operation, ProjectConfig } from '@devpanel/contract';
import { DEFAULT_LIMITS, Engine, aggregate } from '../src/engine.ts';
import { HttpError } from '../src/errors.ts';
import { addVirtualDir } from '../src/validate.ts';

const engines: Engine[] = [];
function mk(): Engine {
  const e = new Engine('/tmp/devpanel-mock-test', { ...DEFAULT_LIMITS, startGraceMs: 50 });
  engines.push(e);
  return e;
}
after(() => engines.forEach((e) => e.stop()));

addVirtualDir('/virtual/proj/a');
addVirtualDir('/virtual/proj/b');

const cfg = (over: Partial<ProjectConfig> = {}): ProjectConfig => ({
  schemaVersion: 1,
  name: 'demo',
  root: '/virtual/proj',
  services: [
    { id: 'a', name: 'A', cwd: 'a', command: ['node', 'server.js'], stopTimeoutSec: 3 },
    { id: 'b', name: 'B', cwd: 'b', command: ['pnpm', 'dev'], env: { PATH: '/usr/bin:/bin' }, stopTimeoutSec: 1 },
  ],
  ...over,
});

async function finished(e: Engine, op: Operation): Promise<Operation> {
  return e.waitOperation(op.id, 10_000);
}

describe('config', () => {
  it('rejects error-level issues with 422 and keeps warnings non-blocking', () => {
    const e = mk();
    assert.throws(
      () => e.register(cfg()),
      (err: unknown) => err instanceof HttpError && err.status === 422 && err.error.code === 'CONFIG_INVALID',
    );
    const ok = cfg({ services: [{ id: 'a', name: 'A', cwd: 'a', command: ['node', 'x.js', '&'] }] });
    const r = e.register(ok);
    assert.equal(r.status, 201);
    assert.ok(e.validate(ok).issues.some((i) => i.code === 'WARN_BACKGROUND_COMMAND'));
  });

  it('dedupes identical root, conflicts on different config, enforces revision', () => {
    const e = mk();
    const base = cfg({ services: [{ id: 'a', name: 'A', cwd: 'a', command: ['node', 'x.js'], env: { API_KEY: { secret: true, value: 's' } } }] });
    const first = e.register(base);
    const again = e.register({ ...base, services: [{ ...base.services[0]!, env: { API_KEY: { secret: true } } }] });
    assert.equal(again.status, 200);
    assert.equal(again.body.project.id, first.body.project.id);
    assert.deepEqual(again.body.project.config.services[0]!.env, { API_KEY: { secret: true } });
    assert.throws(() => e.register({ ...base, name: 'other' }), (err: unknown) => err instanceof HttpError && err.error.code === 'CONFIG_CONFLICT');
    const id = first.body.project.id;
    const upd = e.update(id, { ifRevision: 1, config: { ...base, name: 'renamed', services: [{ ...base.services[0]!, env: { API_KEY: { secret: true } } }] } });
    assert.equal(upd.revision, 2);
    assert.throws(() => e.update(id, { ifRevision: 1, config: base }), (err: unknown) => err instanceof HttpError && err.error.code === 'REVISION_MISMATCH');
  });
});

describe('operations', () => {
  it('project start is partial when one command is missing; start is idempotent', async () => {
    const e = mk();
    const p = e.seedProject(cfg(), { revision: 1, createdAt: Date.now() });
    const op = await finished(e, e.submit({ projectId: p.project.id, action: 'start' }, { client: 'ui', agent: null }));
    assert.equal(op.state, 'partial');
    assert.equal(op.results[0]!.outcome, 'started');
    assert.equal(op.results[1]!.outcome, 'failed');
    assert.equal(op.results[1]!.error?.code, 'COMMAND_NOT_FOUND');
    const again = await finished(e, e.submit({ projectId: p.project.id, action: 'start', serviceIds: ['a'] }, { client: 'cli', agent: null }));
    assert.equal(again.results[0]!.outcome, 'already-running');
    assert.equal(again.results[0]!.runId, op.results[0]!.runId);
    assert.equal(e.view(p).aggregate, 'partial');
  });

  it('stop cancels a pending start, and the start never revives the service', async () => {
    const e = new Engine('/tmp/x', { ...DEFAULT_LIMITS, startGraceMs: 400 });
    engines.push(e);
    const p = e.seedProject(cfg(), { revision: 1, createdAt: Date.now() });
    const start = e.submit({ projectId: p.project.id, action: 'start', serviceIds: ['a'] }, { client: 'cli', agent: null });
    await new Promise((r) => setTimeout(r, 50));
    const stop = e.submit({ projectId: p.project.id, action: 'stop', serviceIds: ['a'] }, { client: 'ui', agent: null });
    const s1 = await finished(e, start);
    const s2 = await finished(e, stop);
    assert.equal(s1.state, 'cancelled');
    assert.equal(s1.cancelledBy, stop.id);
    assert.equal(s2.state, 'succeeded');
    assert.equal(e.view(p).services[0]!.state, 'stopped');
    assert.equal(e.view(p).services[0]!.lastRun?.exit?.reason, 'start-cancelled');
  });

  it('stop timeout keeps stopping + stopTimedOut; restart refuses to start; force-stop ends it', async () => {
    const e = mk();
    const p = e.seedProject(cfg({ services: [{ ...cfg().services[0]!, stopTimeoutSec: 1 }] }), { revision: 1, createdAt: Date.now() });
    e.setProfile(p, 'a', { kind: 'generic', hangOnStop: true });
    await finished(e, e.submit({ projectId: p.project.id, action: 'start' }, { client: 'ui', agent: null }));
    const stop = await finished(e, e.submit({ projectId: p.project.id, action: 'stop' }, { client: 'ui', agent: null }));
    assert.equal(stop.results[0]!.outcome, 'stop-timeout');
    let sv = e.view(p).services[0]!;
    assert.equal(sv.state, 'stopping');
    assert.equal(sv.stopTimedOut, true);
    const restart = await finished(e, e.submit({ projectId: p.project.id, action: 'restart' }, { client: 'ui', agent: null }));
    assert.equal(restart.results[0]!.outcome, 'failed');
    assert.equal(restart.results[0]!.error?.code, 'STOP_TIMEOUT');
    const force = await finished(e, e.submit({ projectId: p.project.id, action: 'force-stop' }, { client: 'ui', agent: null }));
    assert.equal(force.state, 'succeeded');
    sv = e.view(p).services[0]!;
    assert.equal(sv.state, 'stopped');
    assert.equal(sv.lastRun?.exit?.signal, 'SIGKILL');
  });

  it('log paging and stream replay follow seq', async () => {
    const e = mk();
    const p = e.seedProject(cfg({ services: [cfg().services[0]!] }), { revision: 1, createdAt: Date.now() });
    const op = await finished(e, e.submit({ projectId: p.project.id, action: 'start' }, { client: 'ui', agent: null }));
    const runId = op.results[0]!.runId!;
    e.flood(runId, 3000);
    const tail = e.logPage(runId, { limit: 100 });
    assert.equal(tail.lines.length, 100);
    assert.ok(tail.hasMoreBefore);
    const before = e.logPage(runId, { before: tail.lines[0]!.seq, limit: 50 });
    assert.equal(before.lines[before.lines.length - 1]!.seq, tail.lines[0]!.seq - 1);
    const got: number[] = [];
    e.subscribeLogs(runId, tail.lines[0]!.seq - 1, {
      send: (ev) => {
        if (ev.type === 'lines') got.push(...ev.lines.map((l) => l.seq));
      },
      close: () => {},
      backlog: () => 0,
      lastSentSeq: 0,
      pending: [],
      timer: null,
    });
    assert.equal(got[0], tail.lines[0]!.seq);
    assert.equal(got.length, 100);
  });
});

describe('aggregate', () => {
  it('maps service states to the project aggregate', () => {
    assert.equal(aggregate(['idle', 'idle']), 'idle');
    assert.equal(aggregate(['running', 'running']), 'running');
    assert.equal(aggregate(['running', 'stopped']), 'partial');
    assert.equal(aggregate(['running', 'starting']), 'transition');
    assert.equal(aggregate(['failed', 'stopped']), 'failed');
    assert.equal(aggregate(['exited', 'stopped']), 'stopped');
    assert.equal(aggregate(['unknown', 'running']), 'unknown');
  });
});

describe('footprint and tool resources', () => {
  it('keeps tool samples cached and complete, independently of business projects', () => {
    const e = mk();
    assert.equal(e.daemonInfo().toolResources!.total.footprintBytes, null);
    e.sampleAll();
    const info = e.daemonInfo(), tool = info.toolResources!;
    assert.deepEqual(info.self, tool.daemon);
    assert.equal(tool.total.footprintBytes, tool.daemon.footprintBytes! + tool.helpers.footprintBytes!);
    assert.equal(tool.total.processCount, 2);
    assert.equal(tool.total.cpuPercent, 0.8);
    assert.notEqual(tool.total.footprintBytes, tool.total.rssBytes);
    assert.deepEqual(e.daemonInfo(), info, 'reads must not sample again');
  });
  it('sums complete service footprint and leaves a partial measurement unknown', async () => {
    const e = mk();
    e.sim.resourceFailRate = 0;
    const p = e.seedProject(cfg({ services: [cfg().services[0]!] }), { revision: 1, createdAt: Date.now() });
    await finished(e, e.submit({ projectId: p.project.id, action: 'start' }, { client: 'ui', agent: null }));
    e.sampleAll();
    const first = e.lastStats!.projects[p.project.id]!;
    assert.ok(first.total.footprintBytes! > 0, 'memory is available during CPU warmup');
    assert.equal(first.total.footprintBytes, first.services.a!.footprintBytes);
    e.sim.resourceFailRate = 1;
    e.sampleAll();
    const partial = e.lastStats!.projects[p.project.id]!;
    assert.ok(partial.services.a!.processCount! > 1);
    assert.equal(partial.services.a!.status, 'partial');
    assert.equal(partial.total.footprintBytes, null);
    assert.ok(partial.total.rssBytes! > 0);
  });
});
