/**
 * Application state: everything the daemon tells us (snapshot + events), plus UI selection.
 * The daemon is the only source of truth; local state is replaced wholesale on every snapshot.
 */
import type {
  ActionKind,
  ApiError,
  DaemonEvent,
  DaemonInfo,
  Operation,
  Project,
  ProjectView,
  StatsSnapshot,
} from '@devpanel/contract';
import { ApiRequestError, api, isAbort } from '../api/client';
import { streamSse } from '../api/sse';
import { createStore, useStore } from './store';

export type ConnStatus = 'connecting' | 'connected' | 'disconnected';

export interface ConnState {
  status: ConnStatus;
  everConnected: boolean;
  /** Time (ms) of the last event of any kind. */
  lastEventAt: number | null;
  /** When the state on screen was last known to be current (disconnect time). */
  syncedAt: number | null;
  retryAt: number | null;
  error: ApiError | null;
}

export interface ResultEntry {
  opId: string | null;
  /** The POST itself failed (no operation was created). */
  error: ApiError | null;
  action: ActionKind;
  at: number;
}

export interface Toast {
  id: number;
  text: string;
  tone: 'ok' | 'bad';
}

export type DrawerState = { mode: 'create' } | { mode: 'edit'; projectId: string };

export type Dialog =
  | { kind: 'remove'; projectId: string }
  | { kind: 'rules'; projectId: string }
  | { kind: 'json'; projectId: string }
  | { kind: 'force'; projectId: string; serviceIds: string[] | undefined }
  | { kind: 'daemon' };

export interface AppState {
  conn: ConnState;
  daemon: DaemonInfo | null;
  projects: ProjectView[];
  operations: Record<string, Operation>;
  stats: StatsSnapshot | null;
  statsAt: number | null;
  selectedProjectId: string | null;
  selectedService: Record<string, string>;
  results: Record<string, ResultEntry>;
  inflight: Record<string, true>;
  pendingOps: Record<string, string>;
  configs: Record<string, Project>;
  drawer: DrawerState | null;
  dialog: Dialog | null;
  toasts: Toast[];
  sidebarWidth: number;
  wrap: boolean;
}

// ───────────── persisted UI prefs (localStorage; best effort) ─────────────

const PREFS_KEY = 'devpanel.ui.v1';
interface Prefs {
  selectedProjectId?: string | null;
  selectedService?: Record<string, string>;
  sidebarWidth?: number;
  wrap?: boolean;
}
function loadPrefs(): Prefs {
  try {
    return JSON.parse(localStorage.getItem(PREFS_KEY) ?? '{}') as Prefs;
  } catch {
    return {};
  }
}
function savePrefs(p: Prefs): void {
  try {
    localStorage.setItem(PREFS_KEY, JSON.stringify(p));
  } catch {
    /* private mode etc. */
  }
}

const prefs = loadPrefs();

export const appStore = createStore<AppState>({
  conn: { status: 'connecting', everConnected: false, lastEventAt: null, syncedAt: null, retryAt: null, error: null },
  daemon: null,
  projects: [],
  operations: {},
  stats: null,
  statsAt: null,
  selectedProjectId: prefs.selectedProjectId ?? null,
  selectedService: prefs.selectedService ?? {},
  results: {},
  inflight: {},
  pendingOps: {},
  configs: {},
  drawer: null,
  dialog: null,
  toasts: [],
  sidebarWidth: clampWidth(prefs.sidebarWidth ?? 248),
  wrap: prefs.wrap ?? true,
});

let lastSaved = '';
appStore.subscribe(() => {
  const s = appStore.get();
  const p: Prefs = { selectedProjectId: s.selectedProjectId, selectedService: s.selectedService, sidebarWidth: s.sidebarWidth, wrap: s.wrap };
  const json = JSON.stringify(p);
  if (json !== lastSaved) {
    lastSaved = json;
    savePrefs(p);
  }
});

export function useApp<S>(selector: (s: AppState) => S): S {
  return useStore(appStore, selector);
}

function clampWidth(w: number): number {
  return Math.max(200, Math.min(360, Math.round(w)));
}

// ───────────── derived helpers ─────────────

export function isStale(s: AppState): boolean {
  return s.conn.status !== 'connected';
}

export function actionKey(projectId: string, action: ActionKind, serviceIds?: string[]): string {
  return `${projectId}|${action}|${serviceIds?.join(',') ?? '*'}`;
}

export function isPending(s: AppState, key: string): boolean {
  if (s.inflight[key]) return true;
  const opId = s.pendingOps[key];
  if (!opId) return false;
  const op = s.operations[opId];
  return !op || op.finishedAt === null;
}

export function selectedProject(s: AppState): ProjectView | null {
  return s.projects.find((p) => p.id === s.selectedProjectId) ?? null;
}

// ───────────── actions ─────────────

let toastSeq = 0;
export function toast(text: string, tone: Toast['tone'] = 'ok'): void {
  const id = ++toastSeq;
  appStore.set((s) => ({ ...s, toasts: [...s.toasts, { id, text, tone }].slice(-4) }));
  setTimeout(() => appStore.set((s) => ({ ...s, toasts: s.toasts.filter((t) => t.id !== id) })), tone === 'bad' ? 6000 : 3000);
}

export async function copyText(text: string, okMessage = '已复制'): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
    toast(okMessage);
  } catch {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand('copy');
    ta.remove();
    toast(ok ? okMessage : '复制失败，请手动选择文本', ok ? 'ok' : 'bad');
  }
}

export function selectProject(id: string | null): void {
  appStore.set((s) => (s.selectedProjectId === id ? s : { ...s, selectedProjectId: id }));
}

export function moveSelection(delta: number): void {
  const s = appStore.get();
  if (s.projects.length === 0) return;
  const idx = s.projects.findIndex((p) => p.id === s.selectedProjectId);
  const next = idx === -1 ? 0 : Math.max(0, Math.min(s.projects.length - 1, idx + delta));
  selectProject(s.projects[next]!.id);
}

export function selectService(projectId: string, serviceId: string): void {
  appStore.set((s) =>
    s.selectedService[projectId] === serviceId ? s : { ...s, selectedService: { ...s.selectedService, [projectId]: serviceId } },
  );
}

export function setSidebarWidth(w: number): void {
  appStore.patch({ sidebarWidth: clampWidth(w) });
}

export function setWrap(wrap: boolean): void {
  appStore.patch({ wrap });
}

export function openDrawer(d: DrawerState | null): void {
  appStore.patch({ drawer: d });
}

export function openDialog(d: Dialog | null): void {
  appStore.patch({ dialog: d });
}

export function dismissResult(projectId: string): void {
  appStore.set((s) => {
    const { [projectId]: _, ...rest } = s.results;
    return { ...s, results: rest };
  });
}

function upsertOperation(op: Operation): void {
  appStore.set((s) => {
    const prev = s.operations[op.id];
    // never regress a finished operation (wait-poll and events may race)
    if (prev && prev.finishedAt && !op.finishedAt) return s;
    return { ...s, operations: { ...s.operations, [op.id]: op } };
  });
}

export async function runAction(projectId: string, action: ActionKind, serviceIds?: string[]): Promise<void> {
  const key = actionKey(projectId, action, serviceIds);
  if (isPending(appStore.get(), key)) return; // guard against double clicks; the daemon guarantees correctness
  appStore.set((s) => ({ ...s, inflight: { ...s.inflight, [key]: true } }));
  try {
    const op = await api.operate(serviceIds ? { projectId, serviceIds, action } : { projectId, action });
    if (op.projectId !== projectId) return;
    upsertOperation(op);
    appStore.set((s) => {
      const { [key]: _, ...inflight } = s.inflight;
      return {
        ...s,
        inflight,
        pendingOps: { ...s.pendingOps, [key]: op.id },
        results: { ...s.results, [projectId]: { opId: op.id, error: null, action, at: Date.now() } },
      };
    });
    void followOperation(op.id);
  } catch (e) {
    const error: ApiError = e instanceof ApiRequestError ? e.error : { code: 'INTERNAL', message: String(e) };
    appStore.set((s) => {
      const { [key]: _, ...inflight } = s.inflight;
      return { ...s, inflight, results: { ...s.results, [projectId]: { opId: null, error, action, at: Date.now() } } };
    });
  }
}

/** Long-poll the operation as a backup to the event stream (results must not depend on one channel). */
async function followOperation(opId: string): Promise<void> {
  for (let i = 0; i < 20; i++) {
    const cur = appStore.get().operations[opId];
    if (cur?.finishedAt) return;
    try {
      const op = await api.waitOperation(opId, 30_000);
      upsertOperation(op);
      if (op.finishedAt) return;
    } catch {
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

const configLoads = new Map<string, Promise<Project | null>>();

/** Fetch (masked) config for a project; cached per revision. */
export function ensureConfig(projectId: string, revision: number): Promise<Project | null> {
  const cached = appStore.get().configs[projectId];
  if (cached && cached.revision >= revision) return Promise.resolve(cached);
  const k = `${projectId}@${revision}`;
  let p = configLoads.get(k);
  if (!p) {
    p = api
      .project(projectId)
      .then((proj) => {
        if (proj.id !== projectId) return null;
        appStore.set((s) => ({ ...s, configs: { ...s.configs, [projectId]: proj } }));
        return proj;
      })
      .catch(() => null)
      .finally(() => configLoads.delete(k));
    configLoads.set(k, p);
  }
  return p;
}

export function storeConfig(proj: Project): void {
  appStore.set((s) => ({ ...s, configs: { ...s.configs, [proj.id]: proj } }));
}

// ───────────── event stream ─────────────

const BACKOFF = [1000, 2000, 5000, 10000];
const PING_TIMEOUT = 25_000;

function applyEvent(ev: DaemonEvent): void {
  const now = Date.now();
  switch (ev.type) {
    case 'snapshot':
      appStore.set((s) => {
        const ops: Record<string, Operation> = {};
        for (const o of ev.operations) ops[o.id] = o;
        // keep finished operations we started (result bars) if the snapshot no longer lists them
        for (const id of Object.values(s.pendingOps)) if (!ops[id] && s.operations[id]?.finishedAt) ops[id] = s.operations[id]!;
        const ids = new Set(ev.projects.map((p) => p.id));
        const selected =
          s.selectedProjectId && ids.has(s.selectedProjectId) ? s.selectedProjectId : (ev.projects[0]?.id ?? null);
        return {
          ...s,
          conn: { status: 'connected', everConnected: true, lastEventAt: now, syncedAt: now, retryAt: null, error: null },
          daemon: ev.daemon,
          projects: ev.projects,
          operations: ops,
          stats: ev.stats,
          statsAt: ev.stats ? now : null,
          selectedProjectId: selected,
        };
      });
      return;
    case 'project.upsert':
      appStore.set((s) => {
        const idx = s.projects.findIndex((p) => p.id === ev.project.id);
        const projects = idx === -1 ? [...s.projects, ev.project] : s.projects.map((p, i) => (i === idx ? ev.project : p));
        return {
          ...s,
          projects,
          selectedProjectId: s.selectedProjectId ?? ev.project.id,
          conn: { ...s.conn, lastEventAt: now, syncedAt: now },
        };
      });
      return;
    case 'project.remove':
      appStore.set((s) => {
        const idx = s.projects.findIndex((p) => p.id === ev.projectId);
        const projects = s.projects.filter((p) => p.id !== ev.projectId);
        let selected = s.selectedProjectId;
        if (selected === ev.projectId) selected = (projects[Math.min(idx, projects.length - 1)] ?? null)?.id ?? null;
        const { [ev.projectId]: _c, ...configs } = s.configs;
        return { ...s, projects, configs, selectedProjectId: selected, conn: { ...s.conn, lastEventAt: now, syncedAt: now } };
      });
      return;
    case 'operation':
      upsertOperation(ev.operation);
      appStore.set((s) => ({ ...s, conn: { ...s.conn, lastEventAt: now, syncedAt: now } }));
      return;
    case 'stats':
      appStore.set((s) => ({ ...s, stats: ev.stats, statsAt: now, conn: { ...s.conn, lastEventAt: now, syncedAt: now } }));
      return;
    case 'ping':
      appStore.set((s) => ({ ...s, conn: { ...s.conn, lastEventAt: now, syncedAt: now } }));
      return;
  }
}

let started = false;
let wakeRetry: (() => void) | null = null;

/** Skip the current back-off wait and reconnect now. */
export function reconnectNow(): void {
  wakeRetry?.();
}

export function startEvents(): void {
  if (started) return;
  started = true;
  void (async () => {
    let attempt = 0;
    for (;;) {
      const ac = new AbortController();
      let watchdog: ReturnType<typeof setTimeout> | null = null;
      const arm = () => {
        if (watchdog) clearTimeout(watchdog);
        watchdog = setTimeout(() => ac.abort(), PING_TIMEOUT);
      };
      let error: ApiError | null = null;
      try {
        arm();
        await streamSse(
          api.eventsUrl(),
          (_name, data) => {
            arm();
            let ev: DaemonEvent;
            try {
              ev = JSON.parse(data) as DaemonEvent;
            } catch {
              return;
            }
            if (ev.type === 'snapshot') attempt = 0;
            applyEvent(ev);
          },
          ac.signal,
        );
        error = { code: 'DAEMON_UNREACHABLE', message: '事件流已关闭' };
      } catch (e) {
        if (e instanceof ApiRequestError) error = e.error;
        else if (isAbort(e)) error = { code: 'DAEMON_UNREACHABLE', message: '超过 25 秒未收到管理服务的消息' };
        else error = { code: 'DAEMON_UNREACHABLE', message: String(e) };
      } finally {
        if (watchdog) clearTimeout(watchdog);
      }
      const delay = BACKOFF[Math.min(attempt, BACKOFF.length - 1)]!;
      attempt++;
      appStore.set((s) => ({
        ...s,
        conn: {
          ...s.conn,
          status: 'disconnected',
          syncedAt: s.conn.lastEventAt ?? s.conn.syncedAt,
          retryAt: Date.now() + delay,
          error,
        },
      }));
      await new Promise<void>((resolve) => {
        const t = setTimeout(done, delay);
        function done() {
          clearTimeout(t);
          wakeRetry = null;
          resolve();
        }
        wakeRetry = done;
      });
      appStore.set((s) => ({ ...s, conn: { ...s.conn, status: s.conn.everConnected ? 'disconnected' : 'connecting', retryAt: null } }));
    }
  })();
}
