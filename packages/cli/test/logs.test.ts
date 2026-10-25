import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const exec = promisify(execFile);
test("logs 保留 v0.3 的服务/运行组合，摘要与增量选择器互斥", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "dp-cli-logs-"));
  await mkdir(join(home, "run"));
  const requests: string[] = [];
  const server = createServer((req, res) => {
    const path = req.url!;
    requests.push(path);
    res.setHeader("Content-Type", "application/json");
    if (path.endsWith("/view"))
      res.end(JSON.stringify({ id: "p", services: [{ id: "web" }] }));
    else if (path.endsWith("/services/web/runs"))
      res.end(JSON.stringify([{ id: "r", projectId: "p", serviceId: "web" }]));
    else if (path.endsWith("/runs/r"))
      res.end(JSON.stringify({ id: "r", projectId: "p", serviceId: "web" }));
    else if (path.endsWith("/runs/task"))
      res.end(JSON.stringify({ id: "task", projectId: "p", kind: "action" }));
    else if (path.includes("/logs/stream")) {
      res.setHeader("Content-Type", "text/event-stream");
      res.end('event: end\ndata: {"type":"end"}\n\n');
    } else if (path.includes("/logs/search"))
      res.end(JSON.stringify({ runId: 'r', throughSeq: 1000, scannedThroughSeq: 500, hasMore: true, truncated: true, matches: [{ line: { seq: 3, stream: 'err', text: 'ERROR early' }, before: [], after: [] }] }));
    else if (path.includes("/digest"))
      res.end(JSON.stringify({ blocks: [] }));
    else
      res.end(
        JSON.stringify({
          lines: [{ seq: 7, stream: "out", text: "hello" }],
          truncated: false,
        }),
      );
  });
  t.after(async () => {
    await new Promise<void>((done) => server.close(() => done()));
    await rm(home, { recursive: true, force: true });
  });
  await new Promise<void>((done) =>
    server.listen(join(home, "run/devpanel.sock"), done),
  );
  const run = (...args: string[]) =>
    exec(
      process.execPath,
      [resolve(import.meta.dirname, "../src/main.ts"), "logs", "p", ...args],
      { env: { ...process.env, DEVPANEL_HOME: home }, timeout: 15000 },
    );
  for (const selector of [
    [],
    ["--service", "web"],
    ["--run", "r"],
    ["--service", "web", "--run", "r"],
    ["--run", "task"],
  ]) {
    for (const options of [
      [],
      ["--tail", "10"],
      ["--follow"],
      ["--tail", "10", "--follow", "--json"],
    ]) {
      const result = await run(...selector, ...options);
      assert.match(result.stdout, /hello/);
    }
  }
  for (const flag of [
    ["--digest", "--json"],
    ["--after-seq", "6"],
  ]) {
    for (const selector of [
      ["--service", "web"],
      ["--run", "r"],
    ])
      await run(...selector, ...flag);
    await assert.rejects(
      run("--service", "web", "--run", "r", ...flag),
      (e: any) => e.code === 2,
    );
  }
  await assert.rejects(
    exec(
      process.execPath,
      [
        resolve(import.meta.dirname, "../src/main.ts"),
        "activity",
        "p",
        "--before",
        "a_1",
        "--json",
      ],
      { env: { ...process.env, DEVPANEL_HOME: home }, timeout: 15000 },
    ),
    (e: any) => e.code === 2,
  );
  assert.ok(requests.includes("/api/v1/runs/r/logs?limit=200&after=6"));
  const search = await run('--run', 'r', '--search', 'ERROR 中文', '--after-seq', '2', '--through-seq', '1000', '--limit', '5', '--context', '1', '--case-sensitive', '--json');
  assert.equal(JSON.parse(search.stdout).matches[0].line.seq, 3);
  assert.ok(requests.includes('/api/v1/runs/r/logs/search?q=ERROR+%E4%B8%AD%E6%96%87&after=2&through=1000&limit=5&context=1&caseSensitive=true'));
  const textSearch = await run('--search', 'ERROR');
  assert.match(textSearch.stdout, /--after-seq 500 --through-seq 1000/);
  for (const incompatible of [['--search', 'x', '--follow'], ['--search', 'x', '--digest'], ['--search', 'x', '--tail', '5'], ['--context', '1'], ['--case-sensitive']]) {
    await assert.rejects(run(...incompatible), (e: any) => e.code === 2);
  }
  await assert.rejects(
    run("--service", "other", "--run", "r"),
    (e: any) => e.code === 2,
  );
});
