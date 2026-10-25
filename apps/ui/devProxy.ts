/**
 * Dev-only reverse proxy: forwards /api and /auth to the target daemon and injects the
 * Bearer token from its discovery file, so the page in the browser never sees the token.
 *
 *   DEVPANEL_TARGET=mock (default) → <repo>/.devpanel-dev/mock/daemon.json
 *   DEVPANEL_TARGET=real           → $DEVPANEL_HOME/daemon.json
 *                                    (default ~/Library/Application Support/DevPanel/daemon.json)
 */
import { readFileSync, statSync } from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import type { Connect, Plugin } from 'vite';
import type { DaemonDiscovery, ErrorBody } from '@devpanel/contract';

export function discoveryPath(repoRoot: string): { target: 'mock' | 'real'; file: string } {
  const target = process.env.DEVPANEL_TARGET === 'real' ? 'real' : 'mock';
  if (target === 'mock') return { target, file: path.join(repoRoot, '.devpanel-dev', 'mock', 'daemon.json') };
  const home = process.env.DEVPANEL_HOME || path.join(os.homedir(), 'Library', 'Application Support', 'DevPanel');
  return { target, file: path.join(home, 'daemon.json') };
}

let cache: { mtimeMs: number; disc: DaemonDiscovery } | null = null;
function readDiscovery(file: string): DaemonDiscovery | null {
  try {
    const st = statSync(file);
    if (cache && cache.mtimeMs === st.mtimeMs) return cache.disc;
    const disc = JSON.parse(readFileSync(file, 'utf8')) as DaemonDiscovery;
    cache = { mtimeMs: st.mtimeMs, disc };
    return disc;
  } catch {
    cache = null;
    return null;
  }
}

function fail(res: http.ServerResponse, status: number, code: ErrorBody['error']['code'], message: string): void {
  if (res.headersSent) {
    res.destroy();
    return;
  }
  const body: ErrorBody = { error: { code, message } };
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
}

const LOCAL_HOST = /^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/;

export function devpanelProxy(repoRoot: string): Plugin {
  const { target, file } = discoveryPath(repoRoot);
  const handler: Connect.NextHandleFunction = (req, res, next) => {
    const url = req.url ?? '';
    if (!url.startsWith('/api/') && !url.startsWith('/auth/')) return next();
    // The proxy holds a credential: only accept same-origin requests from a loopback host.
    const host = req.headers.host ?? '';
    if (!LOCAL_HOST.test(host)) return fail(res, 403, 'FORBIDDEN_ORIGIN', `dev proxy: 不允许的 Host ${host}`);
    const origin = req.headers.origin;
    if (origin !== undefined && origin !== `http://${host}`) {
      return fail(res, 403, 'FORBIDDEN_ORIGIN', `dev proxy: 不允许的 Origin ${origin}`);
    }
    const disc = readDiscovery(file);
    if (!disc) return fail(res, 502, 'DAEMON_UNREACHABLE', `找不到发现文件 ${file}（${target}）`);
    const headers: http.OutgoingHttpHeaders = { ...req.headers };
    delete headers.origin;
    delete headers.referer;
    delete headers.cookie;
    headers.host = `127.0.0.1:${disc.httpPort}`;
    headers.authorization = `Bearer ${disc.token}`;
    const upstream = http.request(
      { host: '127.0.0.1', port: disc.httpPort, method: req.method, path: url, headers },
      (up) => {
        const h = { ...up.headers };
        delete h['set-cookie'];
        res.writeHead(up.statusCode ?? 502, h);
        if (typeof res.flushHeaders === 'function') res.flushHeaders();
        up.pipe(res);
        // pipe() does not end the client response if the daemon connection drops mid-stream
        // (e.g. SSE): propagate it so the browser notices the disconnect immediately.
        up.on('close', () => {
          if (!res.writableEnded) res.destroy();
        });
      },
    );
    upstream.on('error', (e) => fail(res, 502, 'DAEMON_UNREACHABLE', `无法连接 ${target} daemon：${e.message}`));
    res.on('close', () => upstream.destroy());
    req.pipe(upstream);
  };
  return {
    name: 'devpanel-proxy',
    configureServer(server) {
      server.config.logger.info(`  devpanel → target=${target} · discovery ${file}`);
      server.middlewares.use(handler);
    },
    configurePreviewServer(server) {
      server.middlewares.use(handler);
    },
  };
}
