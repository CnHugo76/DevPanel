/**
 * The single log subscription of the UI: the run currently on screen.
 * Every response / stream event is checked against (projectId, serviceId, runId) and a generation
 * counter, so nothing from a previously viewed run can leak into the buffer.
 */
import { useSyncExternalStore } from 'react';
import type { LogStreamEvent, RunSummary, TaskRunSummary } from '@devpanel/contract';
import { ApiRequestError, api, isAbort } from '../api/client';
import { streamSse } from '../api/sse';
import { appStore } from '../store/app';
import { LogBuffer } from './buffer';

export interface LogTarget {
  projectId: string;
  serviceId: string;
  runId: string;
}

export interface LogStatus {
  loading: boolean;
  error: string | null;
  /** Live stream is open. */
  streaming: boolean;
  /** Stream dropped; will retry. */
  reconnecting: boolean;
  /** Run ended and every line was delivered. */
  ended: boolean;
  endedRun: RunSummary | TaskRunSummary | null;
  /** Daemon dropped older content of this run (limits). */
  truncated: boolean;
  gap: string | null;
  loadingOlder: boolean;
  loadingNewer: boolean;
  /** Collection time of the newest line (ms). */
  lastLineAt: number | null;
}

const PAGE = 1000;
const BACKOFF = [1000, 2000, 5000, 10000];

const initialStatus = (): LogStatus => ({
  loading: false,
  error: null,
  streaming: false,
  reconnecting: false,
  ended: false,
  endedRun: null,
  truncated: false,
  gap: null,
  loadingOlder: false,
  loadingNewer: false,
  lastLineAt: null,
});

export class LogSession {
  target: LogTarget | null = null;
  buffer = new LogBuffer();
  status: LogStatus = initialStatus();
  /** Bumps on every visible change; React subscribes to it. */
  version = 0;
  /** Lines appended live since the counter was last reset (for "N 条新日志"). */
  appendedSinceMark = 0;

  private gen = 0;
  private abort: AbortController | null = null;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private attempt = 0;
  private listeners = new Set<() => void>();
  private raf: number | null = null;
  private lastGapReopen = 0;

  constructor() {
    // When the daemon connection comes back, resume a dropped stream immediately.
    let prev = appStore.get().conn.status;
    appStore.subscribe(() => {
      const cur = appStore.get().conn.status;
      if (cur === 'connected' && prev !== 'connected' && this.target && this.status.reconnecting) {
        this.attempt = 0;
        this.scheduleStream(this.gen, 0);
      }
      prev = cur;
    });
  }

  subscribe = (l: () => void): (() => void) => {
    this.listeners.add(l);
    return () => this.listeners.delete(l);
  };
  getVersion = (): number => this.version;

  private notify(immediate = false): void {
    if (immediate) {
      if (this.raf !== null) cancelAnimationFrame(this.raf);
      this.raf = null;
      this.version++;
      for (const l of [...this.listeners]) l();
      return;
    }
    if (this.raf !== null) return;
    this.raf = requestAnimationFrame(() => {
      this.raf = null;
      this.version++;
      for (const l of [...this.listeners]) l();
    });
  }

  private setStatus(patch: Partial<LogStatus>, immediate = false): void {
    this.status = { ...this.status, ...patch };
    this.notify(immediate);
  }

  private matches(g: number, runId: string): boolean {
    return g === this.gen && this.target !== null && this.target.runId === runId;
  }

  open(target: LogTarget | null): void {
    const t = this.target;
    if (t && target && t.projectId === target.projectId && t.serviceId === target.serviceId && t.runId === target.runId) return;
    this.close();
    this.target = target;
    if (!target) {
      this.notify(true);
      return;
    }
    this.status = { ...initialStatus(), loading: true };
    this.notify(true);
    void this.loadTail(this.gen);
  }

  close(): void {
    this.gen++;
    this.abort?.abort();
    this.abort = null;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = null;
    this.attempt = 0;
    this.buffer = new LogBuffer();
    this.status = initialStatus();
    this.appendedSinceMark = 0;
    this.target = null;
  }

  markSeen(): void {
    if (this.appendedSinceMark !== 0) {
      this.appendedSinceMark = 0;
      this.notify();
    }
  }

  private async loadTail(g: number): Promise<void> {
    const target = this.target!;
    try {
      const page = await api.logs(target.runId, { limit: PAGE });
      if (!this.matches(g, page.runId)) return;
      this.buffer.reset(page.lines, page.hasMoreBefore);
      const last = page.lines[page.lines.length - 1];
      this.setStatus({
        loading: false,
        error: null,
        truncated: page.truncated,
        ended: page.runEnded,
        lastLineAt: last ? Date.parse(last.ts) : null,
      });
      if (!page.runEnded) this.scheduleStream(g, 0);
    } catch (e) {
      if (g !== this.gen) return;
      const msg = e instanceof ApiRequestError ? e.error.message : String(e);
      const notFound = e instanceof ApiRequestError && e.error.code === 'RUN_NOT_FOUND';
      this.setStatus({ loading: false, error: notFound ? '该运行的日志已按保留策略删除' : `加载日志失败：${msg}` });
      if (!notFound) this.retryTimer = setTimeout(() => g === this.gen && void this.loadTail(g), 3000);
    }
  }

  /** Reload the newest page and resume live streaming (used by "跳到最新" when detached). */
  reloadTail(): void {
    if (!this.target) return;
    const target = this.target;
    this.close();
    this.target = target;
    this.status = { ...initialStatus(), loading: true };
    this.notify(true);
    void this.loadTail(this.gen);
  }

  private scheduleStream(g: number, delay: number): void {
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      if (g === this.gen) void this.stream(g);
    }, delay);
  }

  private async stream(g: number): Promise<void> {
    const target = this.target;
    if (!target || this.status.ended || this.buffer.detached) return;
    this.abort?.abort();
    const ac = new AbortController();
    this.abort = ac;
    const after = this.buffer.lastSeq ?? 0;
    this.setStatus({ streaming: true, reconnecting: false });
    let ended = false;
    try {
      await streamSse(
        api.logStreamUrl(target.runId, after),
        (_name, data) => {
          let ev: LogStreamEvent;
          try {
            ev = JSON.parse(data) as LogStreamEvent;
          } catch {
            return;
          }
          if (ev.type === 'ping') {
            this.attempt = 0;
            return;
          }
          if (!this.matches(g, ev.runId)) return;
          this.attempt = 0;
          switch (ev.type) {
            case 'lines': {
              const added = this.buffer.append(ev.lines);
              if (added > 0) {
                this.appendedSinceMark += added;
                const last = ev.lines[ev.lines.length - 1]!;
                this.status = { ...this.status, lastLineAt: Date.parse(last.ts) };
                this.notify();
              }
              break;
            }
            case 'truncated':
              this.setStatus({ truncated: true });
              break;
            case 'gap':
              this.setStatus({ gap: ev.reason });
              // replay from our last seq to fill whatever this connection dropped (at most every 5s)
              if (Date.now() - this.lastGapReopen > 5000) {
                this.lastGapReopen = Date.now();
                ac.abort();
              }
              break;
            case 'end':
              ended = true;
              this.setStatus({ ended: true, endedRun: ev.run, streaming: false });
              break;
          }
        },
        ac.signal,
      );
    } catch (e) {
      if (g !== this.gen) return;
      if (isAbort(e) && this.abort !== ac) return; // superseded
    }
    if (g !== this.gen) return;
    if (ended) return;
    // Stream closed without `end`: reconnect from the last seq we hold.
    const delay = ac.signal.aborted && this.status.gap ? 0 : BACKOFF[Math.min(this.attempt, BACKOFF.length - 1)]!;
    this.attempt++;
    this.setStatus({ streaming: false, reconnecting: true });
    this.scheduleStream(g, delay);
  }

  async loadOlder(): Promise<void> {
    const target = this.target;
    const before = this.buffer.firstSeq;
    if (!target || before === null || !this.buffer.hasMoreBefore || this.status.loadingOlder) return;
    const g = this.gen;
    this.setStatus({ loadingOlder: true }, true);
    try {
      const page = await api.logs(target.runId, { before, limit: PAGE });
      if (!this.matches(g, page.runId)) return;
      const wasDetached = this.buffer.detached;
      this.buffer.prepend(page.lines, page.hasMoreBefore);
      if (page.truncated) this.status = { ...this.status, truncated: true };
      if (this.buffer.detached && !wasDetached) {
        // we dropped the newest lines: stop live streaming until the window is back at the tail
        this.abort?.abort();
        this.abort = null;
        this.status = { ...this.status, streaming: false, reconnecting: false };
      }
    } catch {
      /* keep what we have */
    } finally {
      if (g === this.gen) this.setStatus({ loadingOlder: false }, true);
    }
  }

  async loadNewer(): Promise<void> {
    const target = this.target;
    const after = this.buffer.lastSeq;
    if (!target || after === null || !this.buffer.detached || this.status.loadingNewer) return;
    const g = this.gen;
    this.setStatus({ loadingNewer: true }, true);
    try {
      const page = await api.logs(target.runId, { after, limit: PAGE });
      if (!this.matches(g, page.runId)) return;
      this.buffer.appendPage(page.lines, page.hasMoreAfter);
      if (!this.buffer.detached && !page.runEnded) this.scheduleStream(g, 0);
      if (page.runEnded && !page.hasMoreAfter) this.status = { ...this.status, ended: true };
    } catch {
      /* ignore */
    } finally {
      if (g === this.gen) this.setStatus({ loadingNewer: false }, true);
    }
  }
}

export const logSession = new LogSession();

export function useLogVersion(): number {
  return useSyncExternalStore(logSession.subscribe, logSession.getVersion, logSession.getVersion);
}
