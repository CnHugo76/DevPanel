/**
 * Typed client for the daemon HTTP API (contract/api.md §2).
 * Auth: in the browser build the daemon's HttpOnly session cookie is sent automatically (same origin);
 * in dev the Vite proxy injects the Bearer token. An embedding shell may call setAuthToken().
 */
import {
  API_BASE,
  CLIENT_HEADER,
  type ActionRequest,
  type ApiError,
  type DaemonInfo,
  type LogPage,
  type Operation,
  type Project,
  type ProjectConfig,
  type ProjectStats,
  type ProjectView,
  type RegisterResponse,
  type RunDetail,
  type RunSummary,
  type UpdateRequest,
  type ValidateResult,
} from '@devpanel/contract';

let authToken: string | null = null;

export function setAuthToken(token: string | null): void {
  authToken = token;
}

export function authHeaders(): Record<string, string> {
  return authToken ? { Authorization: `Bearer ${authToken}` } : {};
}

export class ApiRequestError extends Error {
  status: number;
  error: ApiError;
  constructor(status: number, error: ApiError) {
    super(error.message);
    this.status = status;
    this.error = error;
  }
  get code() {
    return this.error.code;
  }
}

export async function readError(res: Response): Promise<ApiRequestError> {
  try {
    const body = (await res.json()) as { error?: ApiError };
    if (body && body.error && typeof body.error.code === 'string') return new ApiRequestError(res.status, body.error);
  } catch {
    /* not JSON */
  }
  const code = res.status === 401 ? 'UNAUTHORIZED' : res.status === 502 || res.status === 503 ? 'DAEMON_UNREACHABLE' : 'INTERNAL';
  return new ApiRequestError(res.status, { code, message: `HTTP ${res.status}` });
}

export function isAbort(e: unknown): boolean {
  return e instanceof DOMException && e.name === 'AbortError';
}

async function request<T>(method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<T> {
  const headers: Record<string, string> = { Accept: 'application/json', ...authHeaders() };
  if (method !== 'GET') headers[CLIENT_HEADER] = 'ui';
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  let res: Response;
  try {
    res = await fetch(API_BASE + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      credentials: 'same-origin',
      cache: 'no-store',
      signal,
    });
  } catch (e) {
    if (isAbort(e)) throw e;
    throw new ApiRequestError(0, { code: 'DAEMON_UNREACHABLE', message: String((e as Error)?.message ?? e) });
  }
  if (!res.ok) throw await readError(res);
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

const enc = encodeURIComponent;

export interface LogQuery {
  before?: number;
  after?: number;
  limit?: number;
}

export const api = {
  daemon: () => request<DaemonInfo>('GET', '/daemon'),
  projects: () => request<ProjectView[]>('GET', '/projects'),
  project: (id: string) => request<Project>('GET', `/projects/${enc(id)}`),
  view: (id: string) => request<ProjectView>('GET', `/projects/${enc(id)}/view`),
  stats: (id: string) => request<ProjectStats>('GET', `/projects/${enc(id)}/stats`),
  register: (cfg: ProjectConfig) => request<RegisterResponse>('POST', '/projects', cfg),
  update: (id: string, req: UpdateRequest) => request<Project>('PUT', `/projects/${enc(id)}`, req),
  remove: (id: string) => request<void>('DELETE', `/projects/${enc(id)}`),
  validate: (cfg: ProjectConfig, signal?: AbortSignal) => request<ValidateResult>('POST', '/config/validate', cfg, signal),
  runs: (projectId: string, serviceId: string, signal?: AbortSignal) =>
    request<RunSummary[]>('GET', `/projects/${enc(projectId)}/services/${enc(serviceId)}/runs`, undefined, signal),
  run: (runId: string) => request<RunDetail>('GET', `/runs/${enc(runId)}`),
  logs: (runId: string, q: LogQuery, signal?: AbortSignal) => {
    const p = new URLSearchParams();
    if (q.before !== undefined) p.set('before', String(q.before));
    if (q.after !== undefined) p.set('after', String(q.after));
    if (q.limit !== undefined) p.set('limit', String(q.limit));
    const qs = p.toString();
    return request<LogPage>('GET', `/runs/${enc(runId)}/logs${qs ? `?${qs}` : ''}`, undefined, signal);
  },
  logStreamUrl: (runId: string, afterSeq: number) => `${API_BASE}/runs/${enc(runId)}/logs/stream?afterSeq=${afterSeq}`,
  eventsUrl: () => `${API_BASE}/events`,
  operate: (req: ActionRequest) => request<Operation>('POST', '/operations', req),
  operation: (id: string) => request<Operation>('GET', `/operations/${enc(id)}`),
  waitOperation: (id: string, timeoutMs: number, signal?: AbortSignal) =>
    request<Operation>('GET', `/operations/${enc(id)}/wait?timeoutMs=${timeoutMs}`, undefined, signal),
};
