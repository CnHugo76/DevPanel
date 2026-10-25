import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createServer } from 'node:http';
import { mkdir } from 'node:fs/promises';
const exec = promisify(execFile),
  cli = resolve(import.meta.dirname, "../src/main.ts");
test("unreachable daemon returns machine-readable exit 3 without fallback execution", async () => {
  const home = await mkdtemp(join(tmpdir(), "devpanel-cli-"));
  try {
    await assert.rejects(
      exec(process.execPath, [cli, "start", "p_missing", "--json"], {
        env: { ...process.env, DEVPANEL_HOME: home },
      }),
      (e: any) => {
        assert.equal(e.code, 3);
        assert.equal(JSON.parse(e.stdout).error.code, "DAEMON_UNREACHABLE");
        assert.equal(e.stderr, "");
        return true;
      },
    );
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
test("invalid command returns usage exit 2", async () => {
  await assert.rejects(
    exec(process.execPath, [cli, "--invalid", "--json"]),
    (e: any) => {
      assert.equal(e.code, 2);
      assert.equal(JSON.parse(e.stdout).error.code, "BAD_REQUEST");
      return true;
    },
  );
});
test('work flags override environment; activity uses task as a filter without attribution headers', async t => {
  const home = await mkdtemp(join(tmpdir(), 'dp-cli-work-')); await mkdir(join(home, 'run'));
  const requests: { path: string; headers: any }[] = [];
  const server = createServer((req, res) => { requests.push({ path: req.url!, headers: req.headers }); res.end('[]'); });
  await new Promise<void>(done => server.listen(join(home, 'run/devpanel.sock'), done));
  t.after(async () => { await new Promise<void>(done => server.close(() => done())); await rm(home, { recursive: true, force: true }); });
  const env = { ...process.env, DEVPANEL_HOME: home, DEVPANEL_PORT: '0', DEVPANEL_TASK: 'env-task', DEVPANEL_TASK_LABEL: '环境工作' };
  await exec(process.execPath, [cli, 'status', '--task', 'flag-task', '--task-label', '命令工作', '--json'], { env });
  assert.equal(requests[0]!.headers['x-devpanel-task'], 'flag-task');
  assert.equal(decodeURIComponent(requests[0]!.headers['x-devpanel-task-label']), '命令工作');
  await exec(process.execPath, [cli, 'activity', 'p', '--task', 'filter-task', '--json'], { env });
  assert.equal(requests[1]!.path, '/api/v1/projects/p/activity?task=filter-task');
  assert.equal(requests[1]!.headers['x-devpanel-task'], undefined);
  await assert.rejects(exec(process.execPath, [cli, 'status', '--task-label', 'name', '--json'], { env: { ...env, DEVPANEL_TASK: '' } }), (e: any) => e.code === 2);
});

test("daemon start reports socket byte limit before creating startup files", async (t) => {
  const base = await mkdtemp(join(tmpdir(), "devpanel-long-"));
  t.after(() => rm(base, { recursive: true, force: true }));
  const home = join(base, "长".repeat(40));
  const { access } = await import("node:fs/promises");
  await assert.rejects(
    exec(process.execPath, [cli, "daemon", "start", "--json"], {
      env: { ...process.env, DEVPANEL_HOME: home, DEVPANEL_PORT: "0" },
    }),
    (e: any) => {
      assert.equal(e.code, 2);
      const error = JSON.parse(e.stdout).error;
      assert.equal(error.code, "BAD_REQUEST");
      assert.match(error.message, /Unix socket/);
      assert.match(
        error.message,
        process.platform === "darwin" ? /104/ : /108/,
      );
      assert.match(error.message, /字节/);
      assert.match(error.message, /DEVPANEL_HOME/);
      return true;
    },
  );
  await assert.rejects(access(join(home, "daemon-start.log")));
});
