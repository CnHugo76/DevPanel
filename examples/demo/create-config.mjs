#!/usr/bin/env node
// Creates files only. Registration and execution remain explicit CLI operations.
import { constants, copyFileSync, mkdirSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function createDemo(directory, nodePath = process.execPath, port = 0) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('port must be an integer from 0 to 65535');
  const root = resolve(directory);
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const config = {
    schemaVersion: 1, name: 'DevPanel demo', root,
    repositories: [], mavenProjects: [],
    params: [{ key: 'port', label: 'HTTP port (0 = available port)', type: 'number', value: port, min: 0, max: 65535 }],
    services: [{ id: 'web', name: 'Demo HTTP', cwd: '.', command: [nodePath, 'server.mjs', '${port}'],
      ready: { check: { kind: 'log', contains: ['Demo ready at'] }, timeoutSec: 15 } }],
  };
  // Exclusive creation never overwrites a user's files.
  writeFileSync(join(root, 'devpanel-demo.json'), JSON.stringify(config, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  copyFileSync(join(dirname(fileURLToPath(import.meta.url)), 'server.mjs'), join(root, 'server.mjs'), constants.COPYFILE_EXCL);
  return join(root, 'devpanel-demo.json');
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length < 3 || process.argv.length > 4) throw new Error('Usage: node create-config.mjs <new-demo-directory> [port]');
  console.log(createDemo(process.argv[2], process.execPath, Number(process.argv[3] ?? 0)));
}
