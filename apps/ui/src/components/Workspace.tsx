import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { ActionKind, ProjectView, ResourceSample, ServiceView } from '@devpanel/contract';
import { formatBytes, formatClock, formatCpu, formatDayTime, formatDuration, shortRunId, tildePath } from '../lib/format';
import {
  aggregateStatus,
  availableActions,
  exitText,
  failureReason,
  isActiveState,
  isStartable,
  operationSummary,
  projectStatus,
  serviceStatus,
  errorText,
} from '../lib/status';
import {
  actionKey,
  copyText,
  dismissResult,
  ensureConfig,
  isPending,
  isStale,
  openDialog,
  openDrawer,
  runAction,
  selectService,
  useApp,
} from '../store/app';
import { useNow } from '../store/store';
import { Spinner, StatusBadge, StatusIcon, useDismiss } from './common';
import { LogPanel } from './LogPanel';
import { duplicateSuffixes } from '../lib/status';

const STALE_REASON = '与管理服务的连接中断，暂不能操作';

export function Workspace({ project }: { project: ProjectView }) {
  const stale = useApp(isStale);
  const syncedAt = useApp((s) => s.conn.syncedAt);
  const selectedMap = useApp((s) => s.selectedService);
  const config = useApp((s) => s.configs[project.id]);
  const single = project.services.length === 1;

  useEffect(() => {
    void ensureConfig(project.id, project.revision);
  }, [project.id, project.revision]);

  const remembered = selectedMap[project.id];
  const service = project.services.find((s) => s.id === remembered) ?? project.services[0]!;
  const onSelect = useCallback((sid: string) => selectService(project.id, sid), [project.id]);

  return (
    <main className={`main${stale ? ' stale' : ''}`}>
      {stale && (
        <div className="banner" role="status">
          ⚠ 与管理服务的连接中断。下面显示的是 <b>{syncedAt ? formatClock(syncedAt) : '—'}</b> 的状态，可能已过期；操作已暂时禁用。
        </div>
      )}
      <Header project={project} single={single} />
      <ResultBar project={project} />
      <ResourceBar project={project} single={single ? service : null} />
      {!single && <ServiceTable project={project} selectedId={service.id} onSelect={onSelect} commands={config?.config.services} />}
      <LogPanel project={project} service={service} onSelectService={onSelect} config={config ?? null} />
    </main>
  );
}

// ───────────── header ─────────────

function ActionButton({
  project,
  action,
  serviceIds,
  enabled,
  reason,
  children,
  className = 'b',
}: {
  project: ProjectView;
  action: ActionKind;
  serviceIds?: string[];
  enabled: boolean;
  reason: string;
  children: React.ReactNode;
  className?: string;
}) {
  const stale = useApp(isStale);
  const pending = useApp((s) => isPending(s, actionKey(project.id, action, serviceIds)));
  const disabled = stale || !enabled || pending;
  return (
    <button
      className={className}
      disabled={disabled}
      title={stale ? STALE_REASON : !enabled ? reason : pending ? '请求进行中' : undefined}
      onClick={() => void runAction(project.id, action, serviceIds)}
    >
      {pending && <Spinner />}
      {children}
    </button>
  );
}

function Header({ project, single }: { project: ProjectView; single: boolean }) {
  const now = useNow();
  const stale = useApp(isStale);
  const projects = useApp((s) => s.projects);
  const suffix = useMemo(() => duplicateSuffixes(projects)[project.id], [projects, project.id]);
  const label = projectStatus(project, now);
  const avail = availableActions(project);
  const forcePending = useApp((s) => isPending(s, actionKey(project.id, 'force-stop', undefined)));
  const showForce = single && avail.forceStop;

  return (
    <div className="head">
      <div className="t">
        <h1>
          <span className="pname" title={project.root}>
            {project.name} {suffix && <em>{suffix}</em>}
          </span>
          {stale ? (
            <>
              <StatusBadge label={{ icon: 'unknown', text: '状态未知', tone: 'purple' }} />
              <span className="lastknown">最后已知：{single ? label.text : aggregateStatus(project).text}</span>
            </>
          ) : (
            <StatusBadge label={label} />
          )}
        </h1>
        <button className="path" title={`${project.root}（点击复制）`} onClick={() => void copyText(project.root, '已复制项目路径')}>
          {tildePath(project.root)}
        </button>
      </div>
      <div className="acts">
        <ActionButton
          project={project}
          action="start"
          enabled={avail.start}
          reason="所有服务都已在运行或处理中"
          className={`b${avail.start && project.runningCount === 0 && !stale ? ' primary' : ''}`}
        >
          ▶ 启动
        </ActionButton>
        {showForce ? (
          <button
            className="b danger"
            disabled={stale || forcePending}
            title={stale ? STALE_REASON : '向仍存活的受管进程发送 SIGKILL'}
            onClick={() => openDialog({ kind: 'force', projectId: project.id, serviceIds: undefined })}
          >
            {forcePending && <Spinner />}⚠ 强制停止
          </button>
        ) : (
          <ActionButton project={project} action="stop" enabled={avail.stop} reason="没有运行中的服务">
            ■ 停止
          </ActionButton>
        )}
        <ActionButton project={project} action="restart" enabled={avail.restart} reason="没有运行中的服务">
          ↻ 重启
        </ActionButton>
        <button className="b" onClick={() => openDrawer({ mode: 'edit', projectId: project.id })} title="编辑项目配置">
          ⚙ 配置
        </button>
        <MoreMenu project={project} />
      </div>
    </div>
  );
}

function MoreMenu({ project }: { project: ProjectView }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const close = useCallback(() => setOpen(false), []);
  useDismiss(open, ref, close);
  const running = project.services.some((s) => isActiveState(s.state) || s.state === 'unknown');
  const stale = useApp(isStale);
  const pick = (fn: () => void) => () => {
    setOpen(false);
    fn();
  };
  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button className="b" onClick={() => setOpen((v) => !v)} aria-haspopup="menu" aria-expanded={open} title="更多">
        ⋯
      </button>
      {open && (
        <div className="menu" role="menu">
          <button role="menuitem" onClick={pick(() => void copyText(project.id, `已复制项目 ID ${project.id}`))}>
            复制项目 ID <span className="why mono">{project.id}</span>
          </button>
          <button role="menuitem" onClick={pick(() => openDialog({ kind: 'rules', projectId: project.id }))}>
            复制 Agent 规则…
          </button>
          <button role="menuitem" onClick={pick(() => openDialog({ kind: 'json', projectId: project.id }))}>
            查看配置 JSON
          </button>
          <hr />
          <button
            role="menuitem"
            className="danger"
            disabled={running || stale}
            onClick={pick(() => openDialog({ kind: 'remove', projectId: project.id }))}
          >
            移除项目…
            {(running || stale) && <span className="why">{stale ? STALE_REASON : '有服务正在运行，请先停止'}</span>}
          </button>
        </div>
      )}
    </div>
  );
}

// ───────────── operation result ─────────────

function ResultBar({ project }: { project: ProjectView }) {
  const entry = useApp((s) => s.results[project.id]);
  const op = useApp((s) => (entry?.opId ? s.operations[entry.opId] : undefined));
  const stats = useApp((s) => s.stats?.projects[project.id]);
  const config = useApp((s) => s.configs[project.id]);
  const limits = useApp((s) => s.daemon?.limits);
  if (!entry) return null;
  const close = (
    <button className="x" onClick={() => dismissResult(project.id)} aria-label="关闭">
      ✕
    </button>
  );
  if (entry.error) {
    return (
      <div className="result bad" role="status">
        <b>请求未被接受：</b>
        <span className="items">{errorText(entry.error)}</span>
        {close}
      </div>
    );
  }
  if (!op || !op.finishedAt) return null;
  const nameOf = (sid: string) => project.services.find((s) => s.id === sid)?.name ?? sid;
  const timeout = op.results.find((r) => r.outcome === 'stop-timeout');
  if (timeout && op.results.length === 1) {
    const sv = project.services.find((s) => s.id === timeout.serviceId);
    const st = stats?.services[timeout.serviceId];
    const count =
      typeof timeout.error?.details?.remaining === 'number'
        ? (timeout.error.details.remaining as number)
        : st && st.runId === sv?.currentRun?.id
          ? st.processCount
          : null;
    const sec =
      typeof timeout.error?.details?.timeoutSec === 'number'
        ? (timeout.error.details.timeoutSec as number)
        : (config?.config.services.find((s) => s.id === timeout.serviceId)?.stopTimeoutSec ?? limits?.defaultStopTimeoutSec ?? 10);
    return (
      <div className="result" role="status">
        <b>停止未完成：</b>
        <span className="items">
          {project.services.length > 1 ? `${nameOf(timeout.serviceId)}：` : ''}已向{count !== null ? ` ${count} 个` : ''}受管进程发送 SIGTERM，{sec} 秒内未全部退出。可继续等待，或强制停止。
        </span>
        {close}
      </div>
    );
  }
  const sum = operationSummary(op, nameOf);
  return (
    <div className={`result${sum.tone === 'ok' ? ' ok' : sum.tone === 'bad' ? ' bad' : ''}`} role="status">
      <b>{sum.title}：</b>
      <span className="items">{sum.items.join(' · ')}</span>
      {op.source !== 'ui' && <span className="muted">（来源 {op.source}）</span>}
      {close}
    </div>
  );
}

// ───────────── resources ─────────────

function cpuCell(s: ResourceSample | undefined): React.ReactNode {
  if (!s || s.status === 'sampling') return <span className="val dim">采样中…</span>;
  if (s.status === 'unavailable' || s.cpuPercent === null) return <span className="val dim">不可用</span>;
  return <span className="val">{formatCpu(s.cpuPercent)}</span>;
}
function memCell(s: ResourceSample | undefined): React.ReactNode {
  if (!s || s.rssBytes === null) return <span className="val dim">{s?.status === 'sampling' || !s ? '采样中…' : '不可用'}</span>;
  return <span className="val">{formatBytes(s.rssBytes)}</span>;
}

function useStatsStale(sample: ResourceSample | undefined, now: number): boolean {
  const stale = useApp(isStale);
  const interval = useApp((s) => s.stats?.intervalMs ?? s.daemon?.limits.statsIntervalMs ?? 2000);
  if (stale) return true;
  if (!sample?.sampledAt) return false;
  return now - Date.parse(sample.sampledAt) > 3 * interval;
}

function ResourceBar({ project, single }: { project: ProjectView; single: ServiceView | null }) {
  const now = useNow();
  const ps = useApp((s) => s.stats?.projects[project.id]);
  const active = project.services.some((s) => s.currentRun !== null);
  const svcStats = single && ps?.services[single.id];
  const sample: ResourceSample | undefined = single
    ? svcStats && svcStats.runId === single.currentRun?.id
      ? svcStats
      : undefined
    : ps?.total;
  const statsStale = useStatsStale(sample, now);
  if (!active) {
    return (
      <div className="res">
        <span className="muted">未运行 · 无资源数据</span>
      </div>
    );
  }
  const run = single?.currentRun ?? null;
  return (
    <div className={`res${statsStale ? ' stalev' : ''}`}>
      <span title="受管进程 CPU 使用率之和；100% = 一个逻辑 CPU 满载，不截断">
        CPU {cpuCell(sample)}
        {sample?.status === 'partial' && (
          <span className="tag" title={sample.note ?? '部分进程无法读取'}>
            部分
          </span>
        )}
      </span>
      <span title="受管进程 RSS 之和，含共享页，可能高估">
        内存 {memCell(sample)} <span className="muted">RSS 估算</span>
      </span>
      {sample?.processCount != null && <span>{sample.processCount} 个进程</span>}
      {run && (
        <>
          <span>
            运行时长 <span className="val">{formatDuration(now - Date.parse(run.startedAt))}</span>
          </span>
          <span className="muted" title={run.id}>
            运行 {shortRunId(run.id)}
            {run.pid !== null ? ` · PID ${run.pid}` : ''}
          </span>
        </>
      )}
      {statsStale ? (
        <span className="tag gray">已过期 · {sample?.sampledAt ? formatClock(sample.sampledAt) : '—'}</span>
      ) : sample?.sampledAt ? (
        <span className="muted">采样于 {Math.max(0, Math.round((now - Date.parse(sample.sampledAt)) / 1000))} 秒前</span>
      ) : null}
    </div>
  );
}

// ───────────── services ─────────────

function serviceNote(sv: ServiceView, command: string[] | undefined, processCount: number | null): { text: string; cls: string } {
  if (sv.configChangedSinceStart && sv.currentRun) return { text: '配置已修改 · 下次启动生效', cls: 'warn' };
  if (sv.state === 'failed') {
    const at = sv.lastRun?.endedAt ? ` · ${formatDayTime(sv.lastRun.endedAt)}` : '';
    const ex = sv.lastRun?.exit;
    const what = ex?.reason === 'spawn-failed' ? '启动失败' : (exitText(ex ?? null) ?? '异常结束');
    return { text: `${what}${at}`, cls: 'bad' };
  }
  if ((sv.state === 'exited' || sv.state === 'stopped') && sv.lastRun?.exit) {
    const ex = sv.lastRun.exit;
    const what = ex.reason === 'self-exit' ? (exitText(ex) ?? '已退出') : ex.reason === 'force-stop' ? '已强制停止' : '已停止';
    return { text: `${what} · ${formatDayTime(ex.at)}`, cls: '' };
  }
  const cmd = command ? command.join(' ') : '';
  const short = cmd.length > 48 ? `${cmd.slice(0, 47)}…` : cmd;
  if (sv.currentRun) return { text: [short, processCount !== null ? `${processCount} 个进程` : ''].filter(Boolean).join(' · '), cls: '' };
  return { text: short || '尚未运行', cls: '' };
}

function ServiceTable({
  project,
  selectedId,
  onSelect,
  commands,
}: {
  project: ProjectView;
  selectedId: string;
  onSelect: (id: string) => void;
  commands: { id: string; command: string[] }[] | undefined;
}) {
  const now = useNow();
  const ps = useApp((s) => s.stats?.projects[project.id]);
  const stale = useApp(isStale);
  return (
    <table className="svc">
      <thead>
        <tr>
          <th style={{ width: 210 }}>状态</th>
          <th>服务</th>
          <th style={{ width: 90 }}>CPU</th>
          <th style={{ width: 100 }}>内存</th>
          <th style={{ width: 90 }}>运行时长</th>
          <th style={{ width: 130 }} />
        </tr>
      </thead>
      <tbody>
        {project.services.map((sv) => {
          const label = serviceStatus(sv, now);
          const st = ps?.services[sv.id];
          const sample = st && st.runId === sv.currentRun?.id ? st : undefined;
          const note = serviceNote(sv, commands?.find((c) => c.id === sv.id)?.command, sample?.processCount ?? null);
          const ids = [sv.id];
          return (
            <tr key={sv.id} className={sv.id === selectedId ? 'sel' : ''} onClick={() => onSelect(sv.id)}>
              <td>
                <span className={`stcell tone-${label.tone}`} title={label.text}>
                  <StatusIcon kind={label.icon} />
                  {label.text}
                </span>
              </td>
              <td>
                <div className="sname">{sv.name}</div>
                {note.text && <div className={`note ${note.cls}`}>{note.text}</div>}
              </td>
              <td className={sv.currentRun ? '' : 'dim'}>
                {sv.currentRun ? (
                  <span className="val">
                    {!sample || sample.status === 'sampling'
                      ? '采样中'
                      : sample.cpuPercent === null
                        ? '不可用'
                        : formatCpu(sample.cpuPercent)}
                    {sample?.status === 'partial' && (
                      <span className="note warn" title={sample.note}>
                        {' '}
                        部分
                      </span>
                    )}
                  </span>
                ) : (
                  '—'
                )}
              </td>
              <td className={sv.currentRun ? '' : 'dim'}>
                {sv.currentRun ? <span className="val">{sample?.rssBytes != null ? formatBytes(sample.rssBytes) : sample ? '不可用' : '采样中'}</span> : '—'}
              </td>
              <td className={sv.currentRun ? '' : 'dim'}>{sv.currentRun ? formatDuration(now - Date.parse(sv.currentRun.startedAt)) : '—'}</td>
              <td onClick={(e) => e.stopPropagation()}>
                <div className="ops">
                  <RowButton project={project} action="start" ids={ids} enabled={isStartable(sv.state)} title="启动" stale={stale}>
                    ▶
                  </RowButton>
                  {sv.state === 'stopping' && sv.stopTimedOut ? (
                    <button
                      className="ib danger"
                      disabled={stale}
                      title={stale ? STALE_REASON : '向仍存活的受管进程发送 SIGKILL'}
                      onClick={() => openDialog({ kind: 'force', projectId: project.id, serviceIds: ids })}
                    >
                      强制停止
                    </button>
                  ) : (
                    <RowButton
                      project={project}
                      action="stop"
                      ids={ids}
                      enabled={isActiveState(sv.state) || sv.state === 'unknown'}
                      title="停止"
                      stale={stale}
                    >
                      ■
                    </RowButton>
                  )}
                  <RowButton project={project} action="restart" ids={ids} enabled={sv.state === 'running'} title="重启" stale={stale}>
                    ↻
                  </RowButton>
                </div>
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

function RowButton({
  project,
  action,
  ids,
  enabled,
  title,
  stale,
  children,
}: {
  project: ProjectView;
  action: ActionKind;
  ids: string[];
  enabled: boolean;
  title: string;
  stale: boolean;
  children: React.ReactNode;
}) {
  const pending = useApp((s) => isPending(s, actionKey(project.id, action, ids)));
  return (
    <button
      className="ib"
      disabled={stale || !enabled || pending}
      title={stale ? STALE_REASON : title}
      aria-label={title}
      onClick={() => void runAction(project.id, action, ids)}
    >
      {pending ? <Spinner /> : children}
    </button>
  );
}
