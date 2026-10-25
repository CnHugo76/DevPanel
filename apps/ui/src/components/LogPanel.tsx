import { useEffect, useMemo, useRef, useState } from 'react';
import type { LogLine, Project, ProjectView, RunSummary, ServiceView } from '@devpanel/contract';
import { api } from '../api/client';
import { joinArgv } from '../lib/argv';
import { formatAgo, formatBytes, formatCount, formatRange, shortRunId } from '../lib/format';
import { runLabel, serviceStatus } from '../lib/status';
import { logSession, useLogVersion } from '../logs/session';
import { findMatches, linesToText, type Match } from '../logs/text';
import { copyText, isStale, setWrap, useApp } from '../store/app';
import { useNow } from '../store/store';
import { StatusIcon } from './common';
import { LogView, type Highlight, type LogViewHandle } from './LogView';

const EMPTY: LogLine[] = [];
const NO_HIGHLIGHT: Highlight = { ranges: new Map(), current: null };

function mergeRuns(fetched: RunSummary[], sv: ServiceView): RunSummary[] {
  const list = fetched.filter((r) => r.serviceId === sv.id);
  for (const r of [sv.lastRun, sv.currentRun]) {
    if (!r) continue;
    const i = list.findIndex((x) => x.id === r.id);
    if (i === -1) list.unshift(r);
    else list[i] = r; // the view is fresher than the fetched list
  }
  return list.sort((a, b) => Date.parse(b.startedAt) - Date.parse(a.startedAt));
}

export function LogPanel({
  project,
  service,
  onSelectService,
  config,
}: {
  project: ProjectView;
  service: ServiceView;
  onSelectService: (id: string) => void;
  config: Project | null;
}) {
  const now = useNow();
  const stale = useApp(isStale);
  const wrap = useApp((s) => s.wrap);
  const limits = useApp((s) => s.daemon?.limits);
  const multi = project.services.length > 1;
  const key = `${project.id}/${service.id}`;

  // ── runs of this service ──
  const [fetched, setFetched] = useState<{ key: string; runs: RunSummary[] } | null>(null);
  const lastRunId = service.lastRun?.id ?? null;
  const lastEnded = service.lastRun?.endedAt ?? null;
  useEffect(() => {
    if (!lastRunId || stale) return;
    const ac = new AbortController();
    const pid = project.id;
    const sid = service.id;
    api
      .runs(pid, sid, ac.signal)
      .then((runs) => {
        if (runs.every((r) => r.projectId === pid && r.serviceId === sid)) setFetched({ key: `${pid}/${sid}`, runs });
      })
      .catch(() => {});
    return () => ac.abort();
  }, [project.id, service.id, lastRunId, lastEnded, stale]);
  const runs = useMemo(() => mergeRuns(fetched?.key === key ? fetched.runs : [], service), [fetched, key, service]);

  // ── which run is on screen ── (auto = newest; explicit = picked from the dropdown)
  const [choice, setChoice] = useState<Record<string, string>>({});
  const latestRunId = service.currentRun?.id ?? service.lastRun?.id ?? null;
  const explicit = choice[key];
  const viewRunId = explicit && runs.some((r) => r.id === explicit) ? explicit : latestRunId;
  const viewRun = runs.find((r) => r.id === viewRunId) ?? null;
  const isHistory = viewRunId !== null && viewRunId !== latestRunId;
  const isLive = viewRun !== null && viewRun.endedAt === null;

  useEffect(() => {
    logSession.open(viewRunId ? { projectId: project.id, serviceId: service.id, runId: viewRunId } : null);
  }, [project.id, service.id, viewRunId]);
  useEffect(() => () => logSession.open(null), []);

  const version = useLogVersion();
  const t = logSession.target;
  const matchesTarget = t !== null && t.projectId === project.id && t.serviceId === service.id && t.runId === viewRunId;
  const lines = matchesTarget ? logSession.buffer.lines : EMPTY;
  const st = logSession.status;
  const buf = logSession.buffer;

  // ── follow ──
  const [follow, setFollow] = useState(true);
  useEffect(() => {
    setFollow(true);
    logSession.markSeen();
  }, [viewRunId]);
  useEffect(() => {
    if (follow) logSession.markSeen();
  }, [follow, version]);
  const newCount = follow ? 0 : logSession.appendedSinceMark;

  // ── search ──
  const [query, setQuery] = useState('');
  const [matches, setMatches] = useState<Match[]>([]);
  const [cur, setCur] = useState(0);
  const searchRef = useRef<HTMLInputElement>(null);
  const curRef = useRef<Match | null>(null);
  const lastSearchAt = useRef(0);
  const lastQuery = useRef('');
  useEffect(() => {
    if (!query) {
      setMatches([]);
      lastQuery.current = '';
      return;
    }
    // throttle (not debounce): while lines stream in, search at most every 300ms
    const typing = query !== lastQuery.current;
    const wait = typing ? 120 : Math.max(0, 300 - (Date.now() - lastSearchAt.current));
    const timer = setTimeout(() => {
      lastSearchAt.current = Date.now();
      lastQuery.current = query;
      const ms = findMatches(logSession.buffer.lines === lines ? lines : EMPTY, query);
      setMatches(ms);
      const prev = curRef.current;
      if (prev) {
        const i = ms.findIndex((m) => m.seq === prev.seq && m.start === prev.start);
        setCur(i >= 0 ? i : 0);
      } else setCur(0);
    }, wait);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query, version, viewRunId]);
  const current = matches[cur] ?? null;
  curRef.current = current;
  const highlight = useMemo<Highlight>(() => {
    if (!matches.length) return NO_HIGHLIGHT;
    const ranges = new Map<number, Array<readonly [number, number]>>();
    for (const m of matches) {
      const arr = ranges.get(m.seq);
      if (arr) arr.push([m.start, m.end]);
      else ranges.set(m.seq, [[m.start, m.end]]);
    }
    return { ranges, current: null };
  }, [matches]);
  const hl = useMemo<Highlight>(
    () => (current ? { ranges: highlight.ranges, current: { seq: current.seq, start: current.start } } : highlight),
    [highlight, current],
  );

  const viewHandle = useRef<LogViewHandle | null>(null);
  const jump = (delta: number) => {
    if (!matches.length) return;
    const next = (cur + delta + matches.length) % matches.length;
    setCur(next);
    setFollow(false);
    const m = matches[next]!;
    requestAnimationFrame(() => viewHandle.current?.scrollToSeq(m.seq));
  };

  useEffect(() => {
    const onFind = () => {
      searchRef.current?.focus();
      searchRef.current?.select();
    };
    window.addEventListener('devpanel:find', onFind);
    return () => window.removeEventListener('devpanel:find', onFind);
  }, []);

  const onSearchKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      jump(e.shiftKey ? -1 : 1);
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      jump(1);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      jump(-1);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      setQuery('');
      searchRef.current?.blur();
    }
  };

  // ── copy ──
  const wrapRef = useRef<HTMLDivElement>(null);
  const onCopy = () => {
    const sel = window.getSelection();
    const text = sel?.toString() ?? '';
    if (text && sel?.anchorNode && wrapRef.current?.contains(sel.anchorNode)) {
      void copyText(text, '已复制选中的日志');
      return;
    }
    if (!lines.length) return;
    void copyText(linesToText(lines), `已复制已加载的 ${formatCount(lines.length)} 行`);
  };

  const jumpLatest = () => {
    if (buf.detached) logSession.reloadTail();
    setFollow(true);
    requestAnimationFrame(() => viewHandle.current?.scrollToEnd());
  };

  const viewCfg = config?.config.services.find((s) => s.id === service.id);
  const cmdText = viewCfg ? joinArgv(viewCfg.command) : null;

  // ── body ──
  let body: React.ReactNode;
  if (!latestRunId) {
    body = (
      <div className="empty">
        <div className="box">
          <h2>该服务尚未运行</h2>
          点击「启动」后，日志会显示在这里。
          <br />
          注册项目不会自动启动。
          {cmdText && (
            <>
              <br />
              <br />
              <span className="cmd">{cmdText}</span>
            </>
          )}
        </div>
      </div>
    );
  } else if (matchesTarget && st.error && lines.length === 0) {
    body = (
      <div className="empty">
        <div className="box">{st.error}</div>
      </div>
    );
  } else if (matchesTarget && !st.loading && lines.length === 0) {
    body = (
      <div className="empty">
        <div className="box">{isLive ? '暂无输出。部分程序会缓冲输出，日志可能延迟出现。' : '该运行没有任何输出。'}</div>
      </div>
    );
  } else {
    body = (
      <div className="lwrap" ref={wrapRef}>
        {st.loadingOlder && <div className="loadmore">正在加载更早的日志…</div>}
        <LogView
          lines={lines}
          version={version}
          wrap={wrap}
          follow={follow && !buf.detached}
          highlight={hl}
          handleRef={viewHandle}
          onLeaveBottom={() => setFollow(false)}
          onReachBottom={() => {
            if (buf.detached) void logSession.loadNewer();
            else setFollow(true);
          }}
          onNearTop={() => void logSession.loadOlder()}
        />
        {(newCount > 0 || buf.detached) && (
          <button className="newpill" onClick={jumpLatest}>
            ↓ {newCount > 0 ? `${formatCount(newCount)} 条新日志 · ` : ''}跳到最新
          </button>
        )}
      </div>
    );
  }

  // ── footer ──
  const foot: React.ReactNode[] = [];
  if (latestRunId) {
    if (lines.length) foot.push(<span key="n">已加载 {formatCount(lines.length)} 行</span>);
    if (st.loading) foot.push(<span key="l">正在加载…</span>);
    if (st.truncated)
      foot.push(
        <span key="t" className="w">
          较早内容已按上限截断（每次运行 {formatBytes(limits?.logBytesPerRun ?? 32 * 1024 * 1024)}）
        </span>,
      );
    if (buf.localTrimmed)
      foot.push(<span key="c">界面最多保留 {formatCount(buf.cap)} 行，向上滚动可按需加载更早内容</span>);
    if (st.gap)
      foot.push(
        <span key="g" className="bad">
          采集中断：{st.gap}
        </span>,
      );
    if (stale || st.reconnecting)
      foot.push(
        <span key="s" className="w">
          日志流已断开，{buf.lastSeq !== null ? `重连后从第 ${formatCount(buf.lastSeq)} 行续接` : '正在重连'}
        </span>,
      );
    else if (isLive && st.lastLineAt && now - st.lastLineAt > 60_000)
      foot.push(<span key="i">暂无新输出 · 最后输出于 {formatAgo(now - st.lastLineAt)}</span>);
    if (!isLive && viewRun) foot.push(<span key="e">运行已结束</span>);
    foot.push(<span key="m">stdout / stderr 按采集顺序合并显示</span>);
  }

  return (
    <section className="logs">
      <div className="ltool">
        {multi && (
          <div className="seg" role="tablist" aria-label="服务">
            {project.services.map((s) => (
              <button
                key={s.id}
                role="tab"
                aria-selected={s.id === service.id}
                className={s.id === service.id ? 'on' : ''}
                onClick={() => onSelectService(s.id)}
                title={serviceStatus(s, now).text}
              >
                <StatusIcon kind={serviceStatus(s, now).icon} pulse={false} />
                {s.name}
              </button>
            ))}
          </div>
        )}
        <select
          className="sel-run"
          value={viewRunId ?? ''}
          disabled={runs.length === 0}
          onChange={(e) => {
            const id = e.target.value;
            setChoice((c) => {
              const next = { ...c };
              if (id === latestRunId) delete next[key];
              else next[key] = id;
              return next;
            });
          }}
          aria-label="选择运行"
        >
          {runs.length === 0 && <option value="">无运行记录</option>}
          {runs.map((r, i) => (
            <option key={r.id} value={r.id}>
              {runLabel(r, service.currentRun ? i : i, r.id === service.currentRun?.id, now)}
            </option>
          ))}
        </select>
        <div className="search">
          <span aria-hidden="true">🔍</span>
          <input
            ref={searchRef}
            value={query}
            placeholder="搜索已加载的日志"
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={onSearchKey}
            aria-label="搜索已加载的日志"
          />
          {query && (
            <>
              <span className="cnt">{matches.length ? `${cur + 1} / ${formatCount(matches.length)}` : '0 / 0'}</span>
              <button className="nav" onClick={() => jump(-1)} disabled={!matches.length} aria-label="上一个">
                ↑
              </button>
              <button className="nav" onClick={() => jump(1)} disabled={!matches.length} aria-label="下一个">
                ↓
              </button>
            </>
          )}
        </div>
        <span className="spacer" />
        <label className="tog">
          <input
            type="checkbox"
            checked={follow && !buf.detached}
            aria-label="跟随"
            onChange={(e) => {
              if (e.target.checked) jumpLatest();
              else setFollow(false);
            }}
          />
          跟随
        </label>
        <label className="tog">
          <input type="checkbox" checked={wrap} aria-label="自动换行" onChange={(e) => setWrap(e.target.checked)} /> 自动换行
        </label>
        <button className="b sm" onClick={onCopy} disabled={!lines.length} title="有选区时复制选区，否则复制已加载的全部">
          复制
        </button>
      </div>
      {isHistory && viewRun && (
        <div className="histbar">
          正在查看历史运行 {shortRunId(viewRun.id)}（{formatRange(viewRun.startedAt, viewRun.endedAt, now)}），不会追加新日志 ·
          <button
            className="link"
            onClick={() =>
              setChoice((c) => {
                const { [key]: _, ...rest } = c;
                return rest;
              })
            }
          >
            {service.currentRun ? '回到当前运行' : '回到最近一次运行'}
          </button>
        </div>
      )}
      {body}
      {foot.length > 0 && <div className="lfoot">{foot}</div>}
    </section>
  );
}
