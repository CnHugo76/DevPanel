import { memo, useCallback, useMemo, useRef, useState } from 'react';
import type { ProjectStats, ProjectView } from '@devpanel/contract';
import { formatAgo, formatBytes, formatCpu, formatDuration, tildePath } from '../lib/format';
import { duplicateSuffixes, projectStatus } from '../lib/status';
import {
  isStale,
  moveSelection,
  openDrawer,
  reconnectNow,
  selectProject,
  setSidebarWidth,
  useApp,
} from '../store/app';
import { useNow } from '../store/store';
import { StatusIcon, useDismiss } from './common';

export function Sidebar() {
  const projects = useApp((s) => s.projects);
  const selected = useApp((s) => s.selectedProjectId);
  const stats = useApp((s) => s.stats);
  const width = useApp((s) => s.sidebarWidth);
  const stale = useApp(isStale);
  const everConnected = useApp((s) => s.conn.everConnected);
  const suffixes = useMemo(() => duplicateSuffixes(projects), [projects]);
  const now = useNow();
  const listRef = useRef<HTMLDivElement>(null);

  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      moveSelection(e.key === 'ArrowDown' ? 1 : -1);
      requestAnimationFrame(() => listRef.current?.querySelector('.pitem.sel')?.scrollIntoView({ block: 'nearest' }));
    }
  };

  return (
    <nav className={`sidebar${stale ? ' stale' : ''}`} style={{ width }} aria-label="项目列表">
      <div className="side-head">
        <b>DevPanel</b>
        <button className="btn-add" onClick={() => openDrawer({ mode: 'create' })} disabled={!everConnected}>
          ＋ 添加项目
        </button>
      </div>
      <div className="plist" role="listbox" tabIndex={0} ref={listRef} onKeyDown={onKey} aria-activedescendant={selected ? `pi-${selected}` : undefined}>
        {projects.map((p) => (
          <ProjectItem
            key={p.id}
            project={p}
            suffix={suffixes[p.id]}
            selected={p.id === selected}
            stats={stats?.projects[p.id]}
            now={now}
          />
        ))}
      </div>
      <ConnFooter now={now} />
      <Resizer />
    </nav>
  );
}

const ProjectItem = memo(function ProjectItem({
  project: p,
  suffix,
  selected,
  stats,
  now,
}: {
  project: ProjectView;
  suffix: string | undefined;
  selected: boolean;
  stats: ProjectStats | undefined;
  now: number;
}) {
  const label = projectStatus(p, now);
  let r2: string;
  if (p.runningCount > 0) {
    const t = stats?.total;
    const short = p.aggregate === 'running' ? '运行中' : label.text.replace(/\s\d+\/\d+$/, '');
    const cpu = !t || t.status === 'sampling' ? '采样中' : t.cpuPercent !== null ? formatCpu(t.cpuPercent) : '不可用';
    const mem = t && t.rssBytes !== null ? ` · ${formatBytes(t.rssBytes)}` : '';
    r2 = `${short} · ${cpu}${mem}`;
  } else {
    const showPath = p.aggregate === 'idle' || p.aggregate === 'stopped';
    r2 = showPath ? `${label.text} · ${tildePath(p.root)}` : label.text;
  }
  return (
    <div
      id={`pi-${p.id}`}
      role="option"
      aria-selected={selected}
      className={`pitem${selected ? ' sel' : ''}`}
      onClick={() => selectProject(p.id)}
      title={p.root}
      aria-label={`${p.name}${suffix ? ` ${suffix}` : ''} · ${label.text}`}
    >
      <div className="r1">
        <StatusIcon kind={label.icon} />
        <span className="name">
          {p.name} {suffix && <em>{suffix}</em>}
        </span>
        <span className="count">
          {p.runningCount}/{p.serviceCount}
        </span>
      </div>
      <div className="r2">{r2}</div>
    </div>
  );
});

function ConnFooter({ now }: { now: number }) {
  const conn = useApp((s) => s.conn);
  const daemon = useApp((s) => s.daemon);
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const close = useCallback(() => setOpen(false), []);
  useDismiss(open, ref, close);

  if (conn.status !== 'connected') {
    const wait = conn.retryAt ? Math.max(0, Math.ceil((conn.retryAt - now) / 1000)) : null;
    const text = conn.error?.code === 'UNAUTHORIZED'
      ? '未登录管理服务 · 请运行 devpanel open'
      : !conn.everConnected
      ? '无法连接管理服务'
      : `管理服务连接中断 · ${wait !== null && wait > 0 ? `${wait} 秒后重连` : '正在重连…'}`;
    return (
      <button className="side-foot bad" onClick={reconnectNow} title="点击立即重连">
        ⚠ {text}
      </button>
    );
  }
  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button className="side-foot" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <StatusIcon kind="running" />
        管理服务已连接{daemon ? ` · v${daemon.version}` : ''}
      </button>
      {open && daemon && (
        <div className="popover" role="dialog" aria-label="管理服务">
          <dl>
            <dt>版本</dt>
            <dd>
              {daemon.version}（API v{daemon.apiVersion}）
            </dd>
            <dt>PID</dt>
            <dd>{daemon.pid}</dd>
            <dt>运行时长</dt>
            <dd>{formatDuration(now - Date.parse(daemon.startedAt))}</dd>
            <dt>自身 CPU</dt>
            <dd>{daemon.self.cpuPercent !== null ? formatCpu(daemon.self.cpuPercent) : daemon.self.status === 'sampling' ? '采样中…' : '不可用'}</dd>
            <dt>自身内存</dt>
            <dd>{daemon.self.rssBytes !== null ? `${formatBytes(daemon.self.rssBytes)}（RSS）` : '不可用'}</dd>
            <dt>数据目录</dt>
            <dd className="mono" style={{ fontSize: 11 }}>
              {tildePath(daemon.home)}
            </dd>
            {conn.lastEventAt && (
              <>
                <dt>最近消息</dt>
                <dd>{formatAgo(now - conn.lastEventAt)}</dd>
              </>
            )}
          </dl>
        </div>
      )}
    </div>
  );
}

function Resizer() {
  const [drag, setDrag] = useState(false);
  const onDown = (e: React.MouseEvent) => {
    e.preventDefault();
    setDrag(true);
    const move = (ev: MouseEvent) => setSidebarWidth(ev.clientX);
    const up = () => {
      setDrag(false);
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  };
  return <div className={`resizer${drag ? ' drag' : ''}`} onMouseDown={onDown} role="separator" aria-orientation="vertical" title="拖拽调整宽度" />;
}
