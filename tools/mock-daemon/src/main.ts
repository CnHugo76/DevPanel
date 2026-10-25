/**
 * Mock DevPanel daemon. Usage:
 *   pnpm --filter @devpanel/mock-daemon start
 * Env:
 *   DEVPANEL_HOME   data dir for daemon.json (default <repo>/.devpanel-dev/mock)
 *   DEVPANEL_PORT   HTTP port (default 47824)
 *   DEVPANEL_UI_DIR static UI to serve at / (default <repo>/apps/ui/dist, if present)
 *   MOCK_NO_SEED=1  start without seed projects
 */
import { chmodSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { DaemonDiscovery } from '@devpanel/contract';
import { Engine } from './engine.ts';
import { seed } from './seed.ts';
import { createMockServer } from './server.ts';
import { iso, newToken } from './util.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '../../..');
const home = path.resolve(process.env.DEVPANEL_HOME || path.join(repoRoot, '.devpanel-dev', 'mock'));
const port = Number(process.env.DEVPANEL_PORT || 47824);
const uiDir = process.env.DEVPANEL_UI_DIR || path.join(repoRoot, 'apps', 'ui', 'dist');

const log = (msg: string) => process.stderr.write(`[mock-daemon ${new Date().toLocaleTimeString()}] ${msg}\n`);

const engine = new Engine(home);
if (process.env.MOCK_NO_SEED !== '1') seed(engine);
engine.start();

const token = newToken();
const { server, issueLoginUrl } = createMockServer({ engine, port, token, uiDir, log });

server.on('error', (e) => {
  log(`监听失败：${e.message}`);
  process.exit(1);
});

server.listen(port, '127.0.0.1', () => {
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('HTTP listener has no TCP address');
  const httpPort = address.port;
  mkdirSync(home, { recursive: true, mode: 0o700 });
  chmodSync(home, 0o700);
  const discovery: DaemonDiscovery = {
    pid: process.pid,
    version: engine.version,
    apiVersion: 1,
    socketPath: path.join(home, 'run', 'devpanel.sock'),
    httpPort,
    token,
    startedAt: iso(engine.startedAt),
  };
  const file = path.join(home, 'daemon.json');
  writeFileSync(file, JSON.stringify(discovery, null, 2) + '\n', { mode: 0o600 });
  chmodSync(file, 0o600);
  log(`监听 http://127.0.0.1:${httpPort}  ·  发现文件 ${file}`);
  log(`项目 ${engine.projects.length} 个（mock 数据，不执行任何真实命令）`);
  log(`浏览器直连（Cookie 登录，需先构建 apps/ui）：${issueLoginUrl()}`);
});

let shuttingDown = false;
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  engine.stop();
  try {
    rmSync(path.join(home, 'daemon.json'), { force: true });
  } catch {
    /* ignore */
  }
  server.closeAllConnections();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 500).unref();
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
