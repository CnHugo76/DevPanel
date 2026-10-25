/**
 * Mapping from contract states to the status language of docs/ui-design.md §3.
 * Status is always icon + text; colour is secondary. Never "健康 / 就绪 / 正常".
 */
import type {
  ActionKind,
  ApiError,
  ExitInfo,
  Operation,
  OperationTargetResult,
  ProjectAggregate,
  ProjectView,
  RunSummary,
  ServiceState,
  ServiceView,
} from '@devpanel/contract';
import { formatDayTime, formatRange } from './format';

export type Tone = 'gray' | 'blue' | 'green' | 'amber' | 'amber-strong' | 'red' | 'purple';
export type IconKind = ServiceState | 'partial';

export interface StatusLabel {
  icon: IconKind;
  text: string;
  tone: Tone;
}

export function exitText(exit: ExitInfo | null): string | null {
  if (!exit) return null;
  if (exit.reason === 'daemon-lost') return '管理服务中断，运行已丢失';
  if (exit.code !== null) return `退出（${exit.code}）`;
  if (exit.signal) return `信号 ${exit.signal}`;
  return null;
}

/** Short human text for an ApiError. */
export function errorText(err: ApiError | null | undefined): string {
  if (!err) return '';
  const d = err.details ?? {};
  switch (err.code) {
    case 'COMMAND_NOT_FOUND': {
      const program = typeof d.program === 'string' ? d.program : null;
      return program ? `命令不存在 ${program}（PATH 中未找到）` : err.message;
    }
    case 'CWD_UNAVAILABLE':
      return typeof d.cwd === 'string' ? `工作目录不可用 ${d.cwd}` : err.message;
    case 'EXITED_DURING_START': {
      const code = typeof d.code === 'number' ? d.code : null;
      const sig = typeof d.signal === 'string' ? d.signal : null;
      return code !== null ? `启动期间退出（${code}）` : sig ? `启动期间被 ${sig} 结束` : '启动期间退出';
    }
    case 'STOP_TIMEOUT':
      return err.message || '旧进程未停止';
    case 'STATE_UNVERIFIABLE':
      return '状态无法核验，已阻止启动';
    case 'OPERATION_CANCELLED':
      return '已被停止操作取消';
    case 'DAEMON_UNREACHABLE':
      return '无法连接管理服务';
    default:
      return err.message || err.code;
  }
}

/** Reason summary for a failed service ("退出（1）", "命令不存在 pnpm（PATH 中未找到）"). */
export function failureReason(sv: Pick<ServiceView, 'error' | 'lastRun'>): string {
  if (sv.error) return errorText(sv.error);
  return exitText(sv.lastRun?.exit ?? null) ?? '原因未知';
}

export function serviceStatus(sv: ServiceView, now: number = Date.now()): StatusLabel {
  switch (sv.state) {
    case 'idle':
      return { icon: 'idle', text: '未启动', tone: 'gray' };
    case 'starting':
      return { icon: 'starting', text: '启动中', tone: 'blue' };
    case 'running':
      return { icon: 'running', text: '运行中', tone: 'green' };
    case 'stopping': {
      const waited = sv.stateSince ? Math.max(0, Math.floor((now - Date.parse(sv.stateSince)) / 1000)) : null;
      if (sv.stopTimedOut) {
        return { icon: 'stopping', text: waited !== null ? `尚未停止（已等待 ${waited} 秒）` : '尚未停止', tone: 'amber-strong' };
      }
      return { icon: 'stopping', text: waited !== null ? `停止中（${waited}s）` : '停止中', tone: 'amber' };
    }
    case 'stopped':
      return { icon: 'stopped', text: '已停止', tone: 'gray' };
    case 'exited': {
      const code = sv.lastRun?.exit?.code;
      return { icon: 'exited', text: code !== undefined && code !== null ? `已退出（${code}）` : '已退出', tone: 'gray' };
    }
    case 'failed':
      return { icon: 'failed', text: `异常 · ${failureReason(sv)}`, tone: 'red' };
    case 'unknown':
      return { icon: 'unknown', text: '状态未知', tone: 'purple' };
  }
}

export function aggregateStatus(pv: Pick<ProjectView, 'aggregate' | 'runningCount' | 'serviceCount'>): StatusLabel {
  const n = `${pv.runningCount}/${pv.serviceCount}`;
  const map: Record<ProjectAggregate, StatusLabel> = {
    running: { icon: 'running', text: `运行中 ${n}`, tone: 'green' },
    partial: { icon: 'partial', text: `部分运行 ${n}`, tone: 'green' },
    transition: { icon: 'starting', text: '处理中', tone: 'blue' },
    failed: { icon: 'failed', text: '异常', tone: 'red' },
    stopped: { icon: 'stopped', text: '已停止', tone: 'gray' },
    idle: { icon: 'idle', text: '未启动', tone: 'gray' },
    unknown: { icon: 'unknown', text: '状态未知', tone: 'purple' },
  };
  return map[pv.aggregate];
}

/**
 * Status shown for a project as a whole (sidebar, header badge).
 * Single-service projects use the service's own, more precise label.
 */
export function projectStatus(pv: ProjectView, now: number = Date.now()): StatusLabel {
  if (pv.services.length === 1) return serviceStatus(pv.services[0]!, now);
  const agg = aggregateStatus(pv);
  if (pv.aggregate === 'transition') {
    const stopping = pv.services.find((s) => s.state === 'stopping');
    if (stopping) return { icon: 'stopping', text: stopping.stopTimedOut ? '尚未停止' : '停止中', tone: stopping.stopTimedOut ? 'amber-strong' : 'amber' };
    return { icon: 'starting', text: '启动中', tone: 'blue' };
  }
  if (pv.aggregate === 'failed') {
    const f = pv.services.find((s) => s.state === 'failed');
    if (f) return { ...agg, text: `异常 · ${f.name} ${failureReason(f)}` };
  }
  return agg;
}

export const isActiveState = (s: ServiceState): boolean => s === 'starting' || s === 'running' || s === 'stopping';
export const isStartable = (s: ServiceState): boolean => s === 'idle' || s === 'stopped' || s === 'exited' || s === 'failed';

export interface ActionAvailability {
  start: boolean;
  stop: boolean;
  restart: boolean;
  /** single-service only: stop timed out → offer force stop in the header */
  forceStop: boolean;
}

export function availableActions(pv: ProjectView): ActionAvailability {
  const states = pv.services.map((s) => s.state);
  return {
    start: states.some(isStartable),
    stop: states.some((s) => isActiveState(s) || s === 'unknown'),
    restart: states.some((s) => s === 'running'),
    forceStop: pv.services.some((s) => s.state === 'stopping' && s.stopTimedOut),
  };
}

// ───────────── operation results ─────────────

const ACTION_VERB: Record<ActionKind, string> = { start: '启动', stop: '停止', restart: '重启', 'force-stop': '强制停止' };

export function outcomeText(r: OperationTargetResult): string {
  switch (r.outcome) {
    case 'pending':
      return '进行中';
    case 'started':
      return '已启动';
    case 'already-running':
      return '已在运行';
    case 'stopped':
      return '已停止';
    case 'already-stopped':
      return '本就未运行';
    case 'stop-timeout':
      return `未在时限内停止${r.error ? `：${errorText(r.error)}` : ''}`;
    case 'failed':
      return `失败：${errorText(r.error) || '原因未知'}`;
    case 'cancelled':
      return '已取消（被停止操作取代）';
  }
}

export interface OperationSummary {
  title: string;
  items: string[];
  tone: 'ok' | 'warn' | 'bad';
}

export function operationSummary(op: Operation, nameOf: (serviceId: string) => string): OperationSummary {
  const verb = ACTION_VERB[op.action];
  const items = op.results.map((r) => `${nameOf(r.serviceId)} ${outcomeText(r)}`);
  const timedOut = op.results.some((r) => r.outcome === 'stop-timeout');
  let title: string;
  let tone: OperationSummary['tone'];
  switch (op.state) {
    case 'succeeded':
      title = op.action === 'start' && op.results.every((r) => r.outcome === 'already-running') ? '已在运行' : `已${verb}`;
      tone = 'ok';
      break;
    case 'partial':
      title = op.action === 'start' || op.action === 'restart' ? '部分运行' : `部分${verb}`;
      tone = 'warn';
      break;
    case 'failed':
      title = timedOut ? '停止未完成' : `${verb}失败`;
      tone = timedOut ? 'warn' : 'bad';
      break;
    case 'cancelled':
      title = `${verb}已取消`;
      tone = 'warn';
      break;
    default:
      title = `${verb}进行中`;
      tone = 'ok';
  }
  return { title, items, tone };
}

// ───────────── runs ─────────────

export function runStateText(run: RunSummary): string {
  switch (run.state) {
    case 'stopped':
      return run.exit?.reason === 'force-stop' ? '已强制停止' : '已停止';
    case 'exited':
      return `已退出（${run.exit?.code ?? 0}）`;
    case 'failed':
      if (run.exit?.reason === 'spawn-failed') return '启动失败';
      return `异常（${run.exit?.code ?? run.exit?.signal ?? '?'}）`;
    case 'starting':
      return '启动中';
    case 'running':
      return '运行中';
    case 'stopping':
      return '停止中';
    case 'unknown':
      return '状态未知';
    default:
      return run.state;
  }
}

/** Dropdown label: "当前运行 · 10:42 起" / "上一次 · 10:12–10:40 · 已停止" / "更早 · 昨天 18:02–19:30 · 异常（1）". */
export function runLabel(run: RunSummary, index: number, isCurrent: boolean, now: number = Date.now()): string {
  if (isCurrent) return `当前运行 · ${formatDayTime(run.startedAt, now)} 起`;
  const prefix = index === 0 ? '最近一次' : index === 1 ? '上一次' : '更早';
  return `${prefix} · ${formatRange(run.startedAt, run.endedAt, now)} · ${runStateText(run)}`;
}

// ───────────── projects ─────────────

/** Gray suffix for projects sharing a name: parent directory, deepened until unique. */
export function duplicateSuffixes(projects: ReadonlyArray<Pick<ProjectView, 'id' | 'name' | 'root'>>): Record<string, string> {
  const byName = new Map<string, Array<Pick<ProjectView, 'id' | 'name' | 'root'>>>();
  for (const p of projects) {
    const list = byName.get(p.name) ?? [];
    list.push(p);
    byName.set(p.name, list);
  }
  const out: Record<string, string> = {};
  for (const group of byName.values()) {
    if (group.length < 2) continue;
    const parents = group.map((p) => p.root.split('/').filter(Boolean).slice(0, -1));
    let depth = 1;
    const maxDepth = Math.max(...parents.map((x) => x.length));
    while (depth < maxDepth) {
      const labels = parents.map((x) => x.slice(-depth).join('/'));
      if (new Set(labels).size === labels.length) break;
      depth++;
    }
    group.forEach((p, i) => {
      const seg = parents[i]!.slice(-depth).join('/');
      out[p.id] = seg ? `(${seg}/)` : '(/)';
    });
  }
  return out;
}
