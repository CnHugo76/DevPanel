/**
 * Tiny helper for the mock-only debug endpoints:
 *   pnpm --filter @devpanel/mock-daemon ctl disconnect 15
 *   pnpm --filter @devpanel/mock-daemon ctl flood [runId] [count]
 *   pnpm --filter @devpanel/mock-daemon ctl login      # one-time cookie login URL for the built UI
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { DaemonDiscovery } from '@devpanel/contract';

const here = path.dirname(fileURLToPath(import.meta.url));
const home = path.resolve(process.env.DEVPANEL_HOME || path.join(here, '../../..', '.devpanel-dev', 'mock'));
const disc = JSON.parse(readFileSync(path.join(home, 'daemon.json'), 'utf8')) as DaemonDiscovery;
const [cmd, a, b] = process.argv.slice(2);

async function post(p: string): Promise<void> {
  const res = await fetch(`http://127.0.0.1:${disc.httpPort}${p}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${disc.token}`, 'x-devpanel-client': 'cli' },
  });
  console.log(res.status, await res.text());
}

switch (cmd) {
  case 'disconnect':
    await post(`/__mock/disconnect?seconds=${encodeURIComponent(a ?? '10')}`);
    break;
  case 'flood': {
    const q = new URLSearchParams();
    if (a) q.set('runId', a);
    if (b) q.set('count', b);
    await post(`/__mock/flood?${q}`);
    break;
  }
  case 'login':
    await post('/__mock/ui-code');
    break;
  default:
    console.error('用法：ctl disconnect <秒> | flood [runId] [count] | login');
    process.exit(2);
}
