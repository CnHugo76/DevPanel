import { requestActor, validateAgentHeader } from './activity.ts';
import { sampleDigest } from "./digest.ts";
import { createReadStream, existsSync, statSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import type { ClientKind, DaemonEvent, ErrorBody, LogStreamEvent } from '@devpanel/contract';
import { type Engine, type LogSubscriber } from './engine.ts';
import { HttpError, badRequest, notFound } from './errors.ts';
import { iso } from './util.ts';

export interface ServerOptions {
  engine: Engine;
  port: number;
  token: string;
  uiDir: string | null;
  log: (msg: string) => void;
}

interface Ctx {
  req: http.IncomingMessage;
  res: http.ServerResponse;
  url: URL;
  client: ClientKind | null;
}

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.json': 'application/json',
  '.woff2': 'font/woff2',
  '.map': 'application/json',
};

export function createMockServer(opts: ServerOptions) {
  const { engine, token, log } = opts;
  const sessions = new Set<string>();
  const codes = new Map<string, number>(); // code -> expiresAt
  const sseClients = new Set<http.ServerResponse>();
  let offlineUntil = 0;

  function httpPort(): number {
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('mock HTTP server is not listening');
    return address.port;
  }

  function sendJson(res: http.ServerResponse, status: number, body: unknown): void {
    if (status === 204) {
      res.writeHead(204).end();
      return;
    }
    const data = JSON.stringify(body);
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
    res.end(data);
  }
  function sendError(res: http.ServerResponse, e: HttpError): void {
    const body: ErrorBody = { error: e.error };
    sendJson(res, e.status, body);
  }

  function readBody(req: http.IncomingMessage): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const chunks: Buffer[] = [];
      let size = 0;
      req.on('data', (c: Buffer) => {
        size += c.length;
        if (size > 2 * 1024 * 1024) {
          reject(badRequest('请求体过大'));
          req.destroy();
          return;
        }
        chunks.push(c);
      });
      req.on('end', () => {
        if (size === 0) return resolve(undefined);
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch {
          reject(badRequest('请求体不是合法 JSON'));
        }
      });
      req.on('error', reject);
    });
  }

  function cookieSession(req: http.IncomingMessage): string | null {
    const raw = req.headers.cookie;
    if (!raw) return null;
    for (const part of raw.split(';')) {
      const [k, ...v] = part.trim().split('=');
      if (k === 'devpanel_session') return v.join('=');
    }
    return null;
  }

  function authed(req: http.IncomingMessage): boolean {
    const auth = req.headers.authorization;
    if (auth === `Bearer ${token}`) return true;
    const s = cookieSession(req);
    return s !== null && sessions.has(s);
  }

  function sseStart(res: http.ServerResponse): void {
    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-store',
      connection: 'keep-alive',
      'x-accel-buffering': 'no',
    });
    res.flushHeaders();
  }
  function sseSend(res: http.ServerResponse, ev: { type: string }): void {
    res.write(`event: ${ev.type}\ndata: ${JSON.stringify(ev)}\n\n`);
  }

  function serveStatic(ctx: Ctx): boolean {
    if (!opts.uiDir || ctx.req.method !== 'GET') return false;
    const p = ctx.url.pathname;
    if (!(p === '/' || p.startsWith('/assets/') || p === '/favicon.svg' || p === '/index.html')) return false;
    const rel = p === '/' ? 'index.html' : p.slice(1);
    const file = path.resolve(opts.uiDir, rel);
    if (!file.startsWith(path.resolve(opts.uiDir) + path.sep) || !existsSync(file) || !statSync(file).isFile()) {
      if (p === '/') {
        ctx.res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
        ctx.res.end('apps/ui/dist 尚未构建。开发模式请使用 pnpm dev:ui。');
        return true;
      }
      return false;
    }
    ctx.res.writeHead(200, {
      'content-type': MIME[path.extname(file)] ?? 'application/octet-stream',
      'cache-control': rel === 'index.html' ? 'no-store' : 'public, max-age=31536000, immutable',
    });
    createReadStream(file).pipe(ctx.res);
    return true;
  }

  // ───────────── routes ─────────────

  type Handler = (ctx: Ctx, params: string[]) => Promise<void> | void;
  const routes: Array<[string, RegExp, Handler]> = [];
  const route = (method: string, pattern: string, h: Handler) => {
    const re = new RegExp('^' + pattern.replace(/:[a-zA-Z]+/g, '([^/]+)') + '$');
    routes.push([method, re, h]);
  };

  const num = (v: string | null): number | undefined => {
    if (v === null || v === '') return undefined;
    const n = Number(v);
    if (!Number.isFinite(n) || n < 0) throw badRequest(`参数不是合法数字：${v}`);
    return Math.floor(n);
  };

  route('GET', '/api/v1/daemon', ({ res }) => sendJson(res, 200, engine.daemonInfo()));
  route('POST', '/api/v1/daemon/shutdown', async ({ req, res, client }) => {
    const body = (await readBody(req)) as { stopServices?: boolean } | undefined;
    const running = engine.projects.some((p) => [...p.services.values()].some((s) => s.currentRunId));
    if (running && !body?.stopServices) {
      throw new HttpError(409, 'PROJECT_RUNNING', '有服务正在运行；如需一并停止请传 stopServices=true');
    }
    const actor = requestActor(client ?? 'cli', req.headers['x-devpanel-agent']);
    if (!body || typeof body.stopServices !== 'boolean') throw badRequest('stopServices 必须为布尔值');
    const ops = [];
    if (body.stopServices) {
      engine.stopAllTasks(actor);
      for (const p of engine.projects) {
        const op = engine.submit({ projectId: p.project.id, action: 'stop' }, actor, true);
        ops.push(await engine.waitOperation(op.id, 60000));
      }
    }
    sendJson(res, 202, ops.find(op => op.state !== 'succeeded') ?? ops.at(-1) ?? {});
    log('收到 shutdown 请求（mock 不会真的退出）');
  });
  route('POST', '/api/v1/config/validate', async ({ req, res }) => {
    sendJson(res, 200, engine.validate(await readBody(req)));
  });
  route('GET', '/api/v1/projects', ({ res }) => sendJson(res, 200, engine.projects.map((p) => engine.view(p))));
  route('POST', '/api/v1/projects', async ({ req, res, client }) => {
    const r = engine.register(await readBody(req), requestActor(client ?? 'cli', req.headers['x-devpanel-agent']));
    sendJson(res, r.status, r.body);
  });
  route('GET', '/api/v1/projects/:id', ({ res }, [id]) => sendJson(res, 200, engine.maskedProject(engine.getProj(id!))));
  route('PUT', '/api/v1/projects/:id', async ({ req, res, client }, [id]) =>
    sendJson(res, 200, engine.update(id!, await readBody(req), requestActor(client ?? 'cli', req.headers['x-devpanel-agent']))),
  );
  route('GET', '/api/v1/projects/:id/policy', ({ res }, [id]) => sendJson(res, 200, engine.getPolicy(id!)));
  route('PUT', '/api/v1/projects/:id/policy', async ({ req, res, client }, [id]) => {
    const actor = requestActor(client ?? 'cli', req.headers['x-devpanel-agent']); engine.policies.ui(actor);
    sendJson(res, 200, engine.setPolicy(id!, await readBody(req), actor));
  });
  route('DELETE', '/api/v1/projects/:id/services/:sid/hold', ({ req, res, client }, [id, sid]) => {
    engine.releaseHold(id!, sid!, requestActor(client ?? 'cli', req.headers['x-devpanel-agent'])); sendJson(res, 204, null);
  });
  route('GET', '/api/v1/projects/:id/activity', ({ res, url }, [id]) => { engine.getProj(id!); sendJson(res, 200, engine.activity.page(id!, url.searchParams.get('before'), Number(url.searchParams.get('limit') ?? 50))); });
  // v1.1-A params
  route('POST', '/api/v1/projects/:id/params', async ({ req, res, client }, [id]) =>
    sendJson(res, 200, engine.addParam(id!, await readBody(req), requestActor(client ?? 'ui', req.headers['x-devpanel-agent']))),
  );
  route('PATCH', '/api/v1/projects/:id/params/:key', async ({ req, res, client }, [id, key]) =>
    sendJson(res, 200, engine.patchParam(id!, key!, await readBody(req), requestActor(client ?? 'ui', req.headers['x-devpanel-agent']))),
  );
  route('DELETE', '/api/v1/projects/:id/params/:key', ({ req, res, url, client }, [id, key]) => {
    const rev = url.searchParams.get('ifRevision');
    const inline = url.searchParams.get('inline');
    if (inline !== null && inline !== 'true' && inline !== 'false') throw badRequest('inline 只能是 true 或 false');
    const ifRevision = rev !== null && /^\d+$/.test(rev) ? Number(rev) : undefined;
    sendJson(res, 200, engine.deleteParam(id!, key!, { ifRevision, inline: inline === 'true' }, requestActor(client ?? 'ui', req.headers['x-devpanel-agent'])));
  });
  route('DELETE', '/api/v1/projects/:id', ({ res }, [id]) => {
    engine.remove(id!);
    sendJson(res, 204, null);
  });
  route('GET', '/api/v1/projects/:id/view', ({ res }, [id]) => sendJson(res, 200, engine.view(engine.getProj(id!))));
  route('GET', '/api/v1/projects/:id/stats', ({ res }, [id]) => {
    engine.getProj(id!);
    const s = engine.lastStats?.projects[id!];
    sendJson(
      res,
      200,
      s ?? { total: { status: 'unavailable', sampledAt: null, cpuPercent: null, rssBytes: null, processCount: null, note: '没有运行中的服务' }, services: {}, tasks: {} },
    );
  });
  route('GET', '/api/v1/projects/:id/git/status', ({ res, url }, [id]) => sendJson(res, 200, engine.git(id!, url.searchParams.get("repositoryId") ?? undefined).status()));
  route('GET', '/api/v1/projects/:id/git/diff', ({ res, url }, [id]) => {
    const staged = url.searchParams.get('staged') ?? 'false';
    const rawContext = url.searchParams.get('context') ?? '3';
    if (!['true', 'false'].includes(staged) || (rawContext !== 'all' && !/^\d+$/.test(rawContext))) throw badRequest('无效 staged 或 context');
    sendJson(res, 200, engine.git(id!, url.searchParams.get("repositoryId") ?? undefined).diff(url.searchParams.get('path'), staged === 'true', rawContext === 'all' ? 'all' : Number(rawContext)));
  });
  route('GET', '/api/v1/projects/:id/git/stashes', ({ res, url }, [id]) => sendJson(res, 200, engine.git(id!, url.searchParams.get("repositoryId") ?? undefined).stashes()));
  for (const op of ['stage', 'unstage', 'commit', 'stash', 'stash/apply'] as const) {
    route('POST', `/api/v1/projects/:id/git/${op}`, async ({ req, res, client, url }, [id]) => {
      const git = engine.git(id!, url.searchParams.get("repositoryId") ?? undefined);
      const body = await readBody(req);
      const result = op === 'stage' ? git.stage(body) : op === 'unstage' ? git.stage(body, true) : op === 'commit' ? git.commit(body) : op === 'stash' ? git.stash(body ?? {}) : git.apply(body);
      sendJson(res, 200, result);
    });
  }
  route('GET', '/api/v1/projects/:id/maven', ({ res, url }, [id]) => {
    const reload = url.searchParams.get('reload');
    if (reload !== null && reload !== '0' && reload !== '1') throw badRequest('reload 只能是 0 或 1');
    sendJson(res, 200, engine.mavenModel(id!, reload === '1', url.searchParams.get('mavenProjectId') ?? undefined));
  });
  route('GET', '/api/v1/projects/:id/maven/runs', ({ res, url }, [id]) => sendJson(res, 200, engine.mavenRuns(id!, url.searchParams.get('mavenProjectId') ?? undefined)));
  route('POST', '/api/v1/projects/:id/maven/runs', async ({ req, res, client }, [id]) => sendJson(res, 202, engine.startMaven(id!, await readBody(req), requestActor(client ?? 'ui', req.headers['x-devpanel-agent']))));
  route('GET', '/api/v1/projects/:id/actions/:aid/runs', ({ res }, [id, aid]) => sendJson(res, 200, engine.actionRuns(id!, aid!)));
  route('POST', '/api/v1/projects/:id/actions/:aid/runs', ({ req, res, client }, [id, aid]) => {
    const result = engine.startAction(id!, aid!, requestActor(client ?? 'ui', req.headers['x-devpanel-agent']));
    sendJson(res, result.created ? 202 : 200, result);
  });
  route('GET', '/api/v1/task-runs/:rid', ({ res }, [rid]) => sendJson(res, 200, engine.taskDetail(rid!)));
  route('POST', '/api/v1/task-runs/:rid/cancel', async ({ req, res }, [rid]) => {
    const body = await readBody(req);
    if (body !== undefined && (typeof body !== 'object' || body === null || Array.isArray(body) || ('force' in body && typeof body.force !== 'boolean'))) throw badRequest('force 必须是布尔值');
    const result = engine.cancelTask(rid!, (body as { force?: boolean } | undefined)?.force ?? false, false, requestActor(typeof req.headers['x-devpanel-client'] === 'string' ? req.headers['x-devpanel-client'] : undefined, req.headers['x-devpanel-agent']));
    sendJson(res, result.endedAt ? 200 : 202, result);
  });
  route('GET', '/api/v1/projects/:id/services/:sid/runs', ({ res }, [id, sid]) => sendJson(res, 200, engine.runsOf(id!, sid!)));
  route('GET', '/api/v1/runs/:rid', ({ res }, [rid]) => sendJson(res, 200, engine.runDetail(rid!)));
  route('GET', '/api/v1/runs/:rid/ready/wait', async ({ res, url }, [rid]) => {
    const run = engine.findLogRun(rid!);
    try { engine.runDetail(rid!); } catch { throw badRequest('任务运行没有就绪条件', { reason: 'task-run' }); }
    const raw = url.searchParams.get('timeoutMs') ?? '60000', ms = Number(raw);
    if (!/^\d+$/.test(raw) || ms > 60000) throw badRequest('timeoutMs 必须在 0–60000');
    const end = Date.now() + ms;
    while (run.summary.ready?.state === 'waiting' && Date.now() < end && !res.destroyed) await new Promise(resolve => setTimeout(resolve, Math.min(25, Math.max(1,end-Date.now()))));
    sendJson(res, 200, run.summary);
  });
  route('GET', '/api/v1/runs/:rid/digest', ({ res, url }, [rid]) => {
    const run = engine.findLogRun(rid!);
    try { sendJson(res, 200, sampleDigest(rid!, run.summary.endedAt !== null, url.searchParams)); }
    catch (error) { throw badRequest(error instanceof Error ? error.message : "摘要参数无效"); }
  });
  route('GET', '/api/v1/runs/:rid/logs', ({ res, url }, [rid]) => {
    const q = url.searchParams;
    const before = num(q.get('before'));
    const after = num(q.get('after'));
    if (before !== undefined && after !== undefined) throw badRequest('before 与 after 不能同时使用');
    const query: { before?: number; after?: number; limit?: number } = {};
    if (before !== undefined) query.before = before;
    if (after !== undefined) query.after = after;
    const limit = num(q.get('limit'));
    if (limit !== undefined) query.limit = limit;
    sendJson(res, 200, engine.logPage(rid!, query));
  });
  route('GET', '/api/v1/runs/:rid/logs/stream', ({ req, res, url }, [rid]) => {
    engine.findLogRun(rid!); // 404 before switching to SSE
    const afterSeq = num(url.searchParams.get('afterSeq')) ?? 0;
    sseStart(res);
    sseClients.add(res);
    let closed = false;
    const sub: LogSubscriber = {
      send: (ev: LogStreamEvent) => {
        if (!closed) sseSend(res, ev);
      },
      close: () => {
        if (closed) return;
        closed = true;
        res.end();
      },
      backlog: () => res.writableLength,
      lastSentSeq: afterSeq,
      pending: [],
      timer: null,
    };
    const unsub = engine.subscribeLogs(rid!, afterSeq, sub);
    const ping = setInterval(() => sub.send({ type: 'ping', at: iso() }), 10_000);
    const cleanup = () => {
      closed = true;
      clearInterval(ping);
      unsub();
      sseClients.delete(res);
    };
    req.on('close', cleanup);
    res.on('close', cleanup);
  });
  route('POST', '/api/v1/operations', async ({ req, res, client }) => {
    sendJson(res, 202, engine.submit(await readBody(req), requestActor(client ?? 'ui', req.headers['x-devpanel-agent'])));
  });
  route('GET', '/api/v1/operations/:oid', ({ res }, [oid]) => sendJson(res, 200, engine.getOperation(oid!)));
  route('GET', '/api/v1/operations/:oid/wait', async ({ res, url }, [oid]) => {
    const t = num(url.searchParams.get('timeoutMs')) ?? 30_000;
    if (t > 60_000) throw badRequest('timeoutMs 不能超过 60000');
    sendJson(res, 200, await engine.waitOperation(oid!, t));
  });
  route('GET', '/api/v1/events', ({ req, res }) => {
    sseStart(res);
    sseClients.add(res);
    sseSend(res, engine.snapshot());
    const listener = (e: DaemonEvent) => sseSend(res, e);
    engine.listeners.add(listener);
    const ping = setInterval(() => sseSend(res, { type: 'ping', at: iso() } as DaemonEvent), 10_000);
    const cleanup = () => {
      clearInterval(ping);
      engine.listeners.delete(listener);
      sseClients.delete(res);
    };
    req.on('close', cleanup);
    res.on('close', cleanup);
  });
  route('POST', '/api/v1/auth/ui-code', () => {
    throw new HttpError(403, 'FORBIDDEN_ORIGIN', '一次性登录码只能通过 Unix socket 获取');
  });

  // mock-only debug endpoints
  route('POST', '/__mock/git/:id', async ({ req, res, client, url }, [id]) => {
    if (client !== 'ui') throw new HttpError(403, 'FORBIDDEN_CLIENT', 'mock Git 控制仅供界面联调');
    const git = engine.git(id!, url.searchParams.get("repositoryId") ?? undefined);
    git.configure(await readBody(req));
    sendJson(res, 200, { ...git.modes });
  });
  route('POST', '/__mock/disconnect', ({ res, url }) => {
    const seconds = num(url.searchParams.get('seconds')) ?? 10;
    sendJson(res, 200, { offlineForSeconds: seconds });
    setTimeout(() => {
      offlineUntil = Date.now() + seconds * 1000;
      for (const c of sseClients) c.destroy();
      sseClients.clear();
      server.closeIdleConnections();
      log(`模拟断连 ${seconds} 秒`);
    }, 20);
  });
  route('POST', '/__mock/flood', ({ res, url }) => {
    const runId = url.searchParams.get('runId') || engine.anyLiveRunId();
    if (!runId) throw notFound('RUN_NOT_FOUND', '没有运行中的服务');
    const count = num(url.searchParams.get('count')) ?? 100_000;
    sendJson(res, 200, engine.flood(runId, Math.min(count, 2_000_000)));
  });
  route('POST', '/__mock/ui-code', ({ res }) => {
    const code = randomBytes(12).toString('hex');
    codes.set(code, Date.now() + 60_000);
    sendJson(res, 200, { code, url: `http://127.0.0.1:${httpPort()}/auth/exchange?code=${code}` });
  });

  function issueLoginUrl(): string {
    const code = randomBytes(12).toString('hex');
    codes.set(code, Date.now() + 10 * 60_000);
    return `http://127.0.0.1:${httpPort()}/auth/exchange?code=${code}`;
  }

  async function handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    if (Date.now() < offlineUntil) {
      req.socket.destroy();
      return;
    }
    const host = req.headers.host ?? '';
    const allowedHosts = new Set([`127.0.0.1:${httpPort()}`, `localhost:${httpPort()}`]);
    if (!allowedHosts.has(host)) {
      sendError(res, new HttpError(403, 'FORBIDDEN_ORIGIN', `不允许的 Host：${host}`));
      return;
    }
    const url = new URL(req.url ?? '/', `http://${host}`);
    const ctx: Ctx = { req, res, url, client: null };
    try {
      if (serveStatic(ctx)) return;
      const origin = req.headers.origin;
      if (origin !== undefined && ![...allowedHosts].some((host) => origin === `http://${host}`)) {
        throw new HttpError(403, 'FORBIDDEN_ORIGIN', `不允许的 Origin：${origin}`);
      }
      if (req.method === 'GET' && url.pathname === '/auth/exchange') {
        const code = url.searchParams.get('code') ?? '';
        const exp = codes.get(code);
        codes.delete(code);
        if (!exp || exp < Date.now()) throw new HttpError(401, 'UNAUTHORIZED', '登录码无效或已过期');
        const sid = randomBytes(24).toString('hex');
        sessions.add(sid);
        res.writeHead(302, {
          location: '/',
          'set-cookie': `devpanel_session=${sid}; HttpOnly; SameSite=Strict; Path=/`,
        });
        res.end();
        return;
      }
      if (!authed(req)) throw new HttpError(401, 'UNAUTHORIZED', '缺少或错误的认证信息');
      validateAgentHeader(typeof req.headers["x-devpanel-client"] === "string" ? req.headers["x-devpanel-client"] : undefined, req.headers["x-devpanel-agent"]);
      const method = req.method ?? 'GET';
      if (method !== 'GET' && method !== 'HEAD') {
        const c = req.headers['x-devpanel-client'];
        if (/^\/api\/v1\/projects\/[^/]+\/git\//.test(url.pathname) && c !== 'ui') throw new HttpError(403, 'FORBIDDEN_CLIENT', 'Git 写操作仅允许界面发起');
        if (c !== 'ui' && c !== 'cli') throw badRequest('非 GET 请求必须带 X-DevPanel-Client: ui|cli');
        ctx.client = c;
      }
      for (const [m, re, h] of routes) {
        if (m !== method) continue;
        const match = re.exec(url.pathname);
        if (!match) continue;
        await h(ctx, match.slice(1).map(decodeURIComponent));
        return;
      }
      if (routes.some(([, re]) => re.test(url.pathname))) throw new HttpError(405, 'BAD_REQUEST', `不支持的方法：${method}`);
      throw new HttpError(404, 'BAD_REQUEST', `未知路由：${url.pathname}`);
    } catch (e) {
      if (res.headersSent) {
        res.end();
        return;
      }
      if (e instanceof HttpError) sendError(res, e);
      else {
        log(`内部错误：${String((e as Error)?.stack ?? e)}`);
        sendError(res, new HttpError(500, 'INTERNAL', String(e)));
      }
    }
  }

  const server = http.createServer((req, res) => {
    void handle(req, res);
  });
  server.keepAliveTimeout = 5000;
  return { server, issueLoginUrl };
}
