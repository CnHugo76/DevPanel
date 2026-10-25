#!/usr/bin/env node
// 在无 Node 的 PATH、空 HOME 与隔离数据中验证已打包的命令，不接触用户安装。
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cleanupSmoke, assertNoSecrets } from './release-smoke-cleanup.mjs';
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

const sourceApp = resolve(process.argv[2] ?? '.devpanel-dev/codex/v04/release/DevPanel.app');
const home = mkdtempSync(join(tmpdir(), 'dp-pkg-'));
const app = join(home, '独立目录 with space/DevPanel.app');
cpSync(sourceApp, app, { recursive: true, verbatimSymlinks: true });
for (const name of ['LICENSE', 'THIRD_PARTY_NOTICES.md']) {
  assert(existsSync(join(app, 'Contents/Resources', name)), `发布包缺少 ${name}`);
}
const runtime = join(app, 'Contents/Resources/runtime');
const cli = join(runtime, 'bin/devpanel'), node = join(runtime, 'node/bin/node');
const env = { PATH: '/usr/bin:/bin', HOME: home, DEVPANEL_HOME: join(home, 'data'), DEVPANEL_PORT: '0', LANG: 'en_US.UTF-8' };
mkdirSync(join(home, 'project'));
const secret = 'v04-release-secret-589164';
writeFileSync(join(home, 'config.json'), JSON.stringify({ schemaVersion: 1, name: '发布包验收', root: join(home, 'project'),
  env: { TOKEN: { secret: true, value: secret } },
  params: [{ key: 'password', label: '密码', type: 'string', secret: true, value: secret }],
  services: [{ id: 'server', name: '服务', cwd: '.', command: [node, '-e', 'console.log("ready", process.env.TOKEN, process.argv[1]); console.log("x".repeat(100)); setInterval(()=>{},1000)', '${password}'], stopTimeoutSec: 2 }],
}));
const outputs = [];
let identities = [];
function processRows() {
  const result = spawnSync('/bin/ps', ['-axo', 'pid,ppid,lstart,command'], { env, encoding: 'utf8' });
  assert.equal(result.status, 0);
  return result.stdout.split('\n').map(line => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.{24})\s+(.*)$/);
    return match ? { pid: Number(match[1]), ppid: Number(match[2]), startedAt: match[3], command: match[4] } : null;
  }).filter(Boolean);
}
const commandHash = text => createHash('sha256').update(text).digest('hex');
function remember(daemonPid) {
  const rows = processRows();
  const owned = new Map(identities.map(identity => [identity.pid, identity]));
  if (daemonPid) {
    const row = rows.find(row => row.pid === daemonPid);
    if (row) owned.set(row.pid, { pid: row.pid, ppid: row.ppid, startedAt: row.startedAt, commandHash: commandHash(row.command) });
  }
  for (let changed = true; changed;) {
    changed = false;
    for (const row of rows) {
      const parent = rows.find(parent => parent.pid === row.ppid);
      if (owned.has(row.pid) || !parent || owned.get(parent.pid)?.startedAt !== parent.startedAt) continue;
      owned.set(row.pid, { pid: row.pid, ppid: row.ppid, startedAt: row.startedAt, commandHash: commandHash(row.command) });
      changed = true;
    }
  }
  identities = [...owned.values()];
}
function command(args) {
  const result = spawnSync(cli, [...args, '--json'], { env, encoding: 'utf8', timeout: 30000 });
  assertNoSecrets({ stdout: result.stdout, stderr: result.stderr }, [secret]);
  outputs.push({ args, status: result.status, stdout: result.stdout, stderr: result.stderr });
  remember();
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, `${args.join(' ')}: ${result.stdout} ${result.stderr}`);
  return args[0] === 'logs' ? result.stdout.trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) : JSON.parse(result.stdout);
}
let project, started = false;
let failure;
try {
  const daemon = command(['daemon', 'start']);
  started = true;
  remember(daemon.pid);
  project = command(['project', 'register', '--config', join(home, 'config.json')]).project.id;
  const operation = command(['start', project]);
  remember();
  const run = operation.results[0].runId;
  assert.equal(operation.state, 'succeeded');
  let page = [];
  for (let i = 0; i < 40; i++) {
    page = command(['logs', project, '--run', run]);
    if (page.some(line => line.stream === 'out' && line.text.includes('ready'))) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  assert(page.some(line => line.stream === 'out' && line.text.includes('ready') && line.text.includes('[REDACTED]')),
    '必须读取业务 stdout，并确认敏感环境变量与选项已遮盖');
  command(['status', project]);
  command(['stop', project]);
  command(['project', 'remove', project]);
  project = undefined;
} catch (error) { failure = error; }
finally {
  let remaining = [];
  try {
    await cleanupSmoke({
      stopProject: () => { if (started && project) command(['stop', project]); },
      stopDaemon: () => { if (started) command(['daemon', 'stop']); },
      audit: async () => {
        for (let i = 0; i < 100; i++) {
          remember();
          remaining = processRows().filter(row => identities.some(old => old.pid === row.pid && old.startedAt === row.startedAt));
          if (!remaining.length) break;
          await new Promise(resolve => setTimeout(resolve, 50));
        }
        const leaked = remaining.map(({ pid, ppid, startedAt }) => ({ pid, ppid, startedAt }));
        // Failure cleanup still verifies every saved PID, start time and command before signaling.
        for (const signal of ['SIGTERM', 'SIGKILL']) {
          const rows = processRows();
          for (const old of [...identities].reverse()) {
            const row = rows.find(row => row.pid === old.pid && row.startedAt === old.startedAt && commandHash(row.command) === old.commandHash);
            if (row) { try { process.kill(row.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; } }
          }
          await new Promise(resolve => setTimeout(resolve, 100));
        }
        remaining = processRows().filter(row => identities.some(old => old.pid === row.pid && old.startedAt === row.startedAt))
          .map(({ pid, ppid, startedAt }) => ({ pid, ppid, startedAt }));
        assert.deepEqual(remaining, [], '本轮发布包进程必须全部退出');
        assert.deepEqual(leaked, [], '正常关闭后不得遗留已核验进程');
        assert(!existsSync(join(env.DEVPANEL_HOME, 'daemon.json')));
      },
    });
  } catch (error) { failure = failure ? new AggregateError([failure, error], '发布包验证与清理失败') : error; }
  const report = { app, home, env, outputs, identities, remaining, failure: failure?.message };
  assertNoSecrets(report, [secret]);
  writeFileSync(join(home, 'result.json'), JSON.stringify(report, null, 2));
  if (failure) throw failure;
  console.log(`发布包无外部 Node 验证通过：${home}/result.json`);
}
