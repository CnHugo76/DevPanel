import { describe, expect, it } from 'vitest';
import type { Operation, ProjectView, RunSummary, ServiceState, ServiceView } from '@devpanel/contract';
import { formatBytes, formatCpu, formatDuration, formatRange, tildePath } from '../src/lib/format';
import {
  aggregateStatus,
  availableActions,
  duplicateSuffixes,
  errorText,
  failureReason,
  operationSummary,
  projectStatus,
  runLabel,
  serviceStatus,
} from '../src/lib/status';

const T0 = Date.parse('2026-10-20T02:42:07.118Z');

function run(over: Partial<RunSummary> = {}): RunSummary {
  return {
    id: 'r_01JC8ZB3P1XYZ',
    projectId: 'p_1',
    serviceId: 's',
    configRevision: 1,
    startedAt: new Date(T0).toISOString(),
    endedAt: null,
    pid: 4182,
    state: 'running',
    exit: null,
    ...over,
  };
}

function svc(state: ServiceState, over: Partial<ServiceView> = {}): ServiceView {
  return {
    id: 's',
    name: '后端',
    state,
    stateSince: new Date(T0).toISOString(),
    currentRun: null,
    lastRun: null,
    stopTimedOut: false,
    pendingOperationId: null,
    configChangedSinceStart: false,
    error: null,
    ...over,
  };
}

function project(services: ServiceView[], aggregate: ProjectView['aggregate']): ProjectView {
  return {
    id: 'p_1',
    name: 'order-service',
    root: '/Users/demo/Project/order-service',
    revision: 1,
    aggregate,
    runningCount: services.filter((s) => s.state === 'running').length,
    serviceCount: services.length,
    actions: [],
    maven: null,
    services,
  };
}

describe('serviceStatus', () => {
  it('maps every state to icon + text', () => {
    expect(serviceStatus(svc('idle')).text).toBe('未启动');
    expect(serviceStatus(svc('starting')).text).toBe('启动中');
    expect(serviceStatus(svc('running'))).toEqual({ icon: 'running', text: '运行中', tone: 'green' });
    expect(serviceStatus(svc('stopping'), T0 + 4200).text).toBe('停止中（4s）');
    expect(serviceStatus(svc('stopping', { stopTimedOut: true }), T0 + 10_000)).toEqual({
      icon: 'stopping',
      text: '尚未停止（已等待 10 秒）',
      tone: 'amber-strong',
    });
    expect(serviceStatus(svc('stopped')).text).toBe('已停止');
    expect(serviceStatus(svc('unknown')).text).toBe('状态未知');
  });

  it('exited with code 0 is only "已退出（0）"', () => {
    const s = svc('exited', { lastRun: run({ state: 'exited', exit: { reason: 'self-exit', code: 0, signal: null, at: '' } }) });
    expect(serviceStatus(s).text).toBe('已退出（0）');
  });

  it('failed shows a reason from the error or the exit info', () => {
    const viaExit = svc('failed', { lastRun: run({ state: 'failed', exit: { reason: 'self-exit', code: 1, signal: null, at: '' } }) });
    expect(serviceStatus(viaExit).text).toBe('异常 · 退出（1）');
    const viaError = svc('failed', {
      error: { code: 'COMMAND_NOT_FOUND', message: '在 PATH 中找不到 npm', details: { program: 'npm', pathUsed: '/usr/bin' } },
    });
    expect(serviceStatus(viaError)).toEqual({ icon: 'failed', text: '异常 · 命令不存在 npm（PATH 中未找到）', tone: 'red' });
  });

  it('never uses forbidden wording', () => {
    const all: ServiceState[] = ['idle', 'starting', 'running', 'stopping', 'stopped', 'exited', 'failed', 'unknown'];
    for (const st of all) expect(serviceStatus(svc(st)).text).not.toMatch(/健康|就绪|验证通过|正常/);
  });
});

describe('aggregate labels', () => {
  it('maps ProjectAggregate', () => {
    const a = (aggregate: ProjectView['aggregate'], running: number, total: number) =>
      aggregateStatus({ aggregate, runningCount: running, serviceCount: total }).text;
    expect(a('running', 2, 2)).toBe('运行中 2/2');
    expect(a('partial', 1, 2)).toBe('部分运行 1/2');
    expect(a('transition', 0, 2)).toBe('处理中');
    expect(a('failed', 0, 2)).toBe('异常');
    expect(a('stopped', 0, 2)).toBe('已停止');
    expect(a('idle', 0, 2)).toBe('未启动');
    expect(a('unknown', 0, 2)).toBe('状态未知');
  });

  it('single-service projects use the service label', () => {
    const p = project([svc('stopping', { stopTimedOut: true })], 'transition');
    expect(projectStatus(p, T0 + 3000).text).toBe('尚未停止（已等待 3 秒）');
  });
});

describe('availableActions', () => {
  it('derives start/stop/restart availability', () => {
    expect(availableActions(project([svc('running'), svc('running')], 'running'))).toEqual({
      start: false,
      stop: true,
      restart: true,
      forceStop: false,
    });
    expect(availableActions(project([svc('idle')], 'idle'))).toMatchObject({ start: true, stop: false, restart: false });
    expect(availableActions(project([svc('running'), svc('failed')], 'partial'))).toMatchObject({ start: true, stop: true, restart: true });
    expect(availableActions(project([svc('stopping', { stopTimedOut: true })], 'transition')).forceStop).toBe(true);
  });
});

describe('operationSummary', () => {
  it('lists per-service outcomes for a partial start', () => {
    const op: Operation = {
      id: 'op_1',
      projectId: 'p_1',
      action: 'start',
      serviceIds: ['backend', 'frontend'],
      source: 'ui',
      state: 'partial',
      createdAt: '',
      finishedAt: '',
      cancelledBy: null,
      results: [
        { serviceId: 'backend', outcome: 'started', runId: 'r_1', error: null },
        {
          serviceId: 'frontend',
          outcome: 'failed',
          runId: 'r_2',
          error: { code: 'COMMAND_NOT_FOUND', message: 'x', details: { program: 'npm' } },
        },
      ],
    };
    const names: Record<string, string> = { backend: '后端', frontend: '前端' };
    const s = operationSummary(op, (id) => names[id]!);
    expect(s.title).toBe('部分运行');
    expect(s.items.join(' · ')).toBe('后端 已启动 · 前端 失败：命令不存在 npm（PATH 中未找到）');
    expect(s.tone).toBe('warn');
  });

  it('describes cancellation and stop timeouts', () => {
    const base = { id: 'op', projectId: 'p', serviceIds: ['a'], source: 'cli' as const, createdAt: '', finishedAt: '', cancelledBy: 'op_2' };
    expect(
      operationSummary({ ...base, action: 'restart', state: 'cancelled', results: [{ serviceId: 'a', outcome: 'cancelled', runId: null, error: null }] }, () => 'A')
        .items[0],
    ).toBe('A 已取消（被停止操作取代）');
    expect(
      operationSummary({ ...base, action: 'stop', state: 'failed', results: [{ serviceId: 'a', outcome: 'stop-timeout', runId: 'r', error: null }] }, () => 'A')
        .title,
    ).toBe('停止未完成');
  });

  it('errorText falls back to the daemon message', () => {
    expect(errorText({ code: 'INTERNAL', message: 'boom' })).toBe('boom');
    expect(errorText({ code: 'EXITED_DURING_START', message: 'x', details: { code: 0 } })).toBe('启动期间退出（0）');
  });
});

describe('runs and projects', () => {
  it('labels runs for the dropdown', () => {
    const now = Date.parse('2026-10-20T12:00:00');
    const cur = run({ startedAt: new Date('2026-10-20T10:42:00').toISOString() });
    expect(runLabel(cur, 0, true, now)).toBe('当前运行 · 10:42 起');
    const prev = run({
      startedAt: new Date('2026-10-20T10:12:00').toISOString(),
      endedAt: new Date('2026-10-20T10:40:00').toISOString(),
      state: 'stopped',
      exit: { reason: 'user-stop', code: null, signal: 'SIGTERM', at: '' },
    });
    expect(runLabel(prev, 1, false, now)).toBe('上一次 · 10:12–10:40 · 已停止');
    const old = run({
      startedAt: new Date('2026-10-19T18:02:00').toISOString(),
      endedAt: new Date('2026-10-19T19:30:00').toISOString(),
      state: 'failed',
      exit: { reason: 'self-exit', code: 1, signal: null, at: '' },
    });
    expect(runLabel(old, 2, false, now)).toBe('更早 · 昨天 18:02–19:30 · 异常（1）');
  });

  it('disambiguates duplicate project names by parent directory', () => {
    const s = duplicateSuffixes([
      { id: 'a', name: 'order-service', root: '/Users/h/Project/order-service' },
      { id: 'b', name: 'order-service', root: '/Users/h/Project/archive/order-service' },
      { id: 'c', name: 'unique', root: '/x/unique' },
    ]);
    expect(s).toEqual({ a: '(Project/)', b: '(archive/)' });
    const deep = duplicateSuffixes([
      { id: 'a', name: 'api', root: '/w/one/src/api' },
      { id: 'b', name: 'api', root: '/w/two/src/api' },
    ]);
    expect(deep).toEqual({ a: '(one/src/)', b: '(two/src/)' });
  });
});

describe('format', () => {
  it('formats bytes, cpu and durations', () => {
    expect(formatBytes(190 * 1024 * 1024)).toBe('190 MiB');
    expect(formatBytes(12.5 * 1024 * 1024)).toBe('12.5 MiB');
    expect(formatBytes(32 * 1024 * 1024)).toBe('32 MiB');
    expect(formatBytes(1.21 * 1024 ** 3)).toBe('1.21 GiB');
    expect(formatCpu(132.44)).toBe('132.4%');
    expect(formatCpu(250)).toBe('250.0%');
    expect(formatDuration((72 * 60 + 5) * 1000)).toBe('1h12m');
    expect(formatDuration(185_000)).toBe('3m05s');
    expect(formatDuration(45_000)).toBe('45s');
    expect(tildePath('/Users/demo/Project/foo')).toBe('~/Project/foo');
    expect(formatRange('2026-10-20T10:00:00', null, Date.parse('2026-10-20T12:00:00'))).toBe('10:00 起');
  });
});

describe('failureReason', () => {
  it('names a run lost to a daemon crash instead of "原因未知"', () => {
    const lastRun = run({ state: 'failed', endedAt: new Date(T0).toISOString(), exit: { reason: 'daemon-lost', code: null, signal: null, at: new Date(T0).toISOString() } });
    expect(failureReason(svc('failed', { lastRun }))).toBe('管理服务中断，运行已丢失');
  });
});
