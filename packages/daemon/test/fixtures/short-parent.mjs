import { spawn } from 'node:child_process';
// The detached child starts after the root's initial scan. The parent exists for
// less than the old 2s fallback interval; once it exits, PPID cannot prove ownership.
setTimeout(() => {
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
    detached: true, stdio: 'inherit',
  });
  child.unref();
  setTimeout(() => process.exit(0), 900);
}, 500);
