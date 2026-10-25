import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, rm, writeFile, readFile, mkdir, rename, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Git } from "../src/git.ts";
import { baseEnvironment } from "../src/config.ts";
import { startServer } from "../src/server.ts";
const exec = promisify(execFile);
async function fixture(t: TestContext, cleanup = true) {
  const home = await mkdtemp(join(tmpdir(), "dp-git-")); const root = join(home, "repo"); await mkdir(root);
  const command = (...args: string[]) => exec("/usr/bin/git", args, { cwd: root, env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" } }).then(r => r.stdout.trim());
  await command("init", "-b", "main"); await command("config", "user.name", "DevPanel Test"); await command("config", "user.email", "test@example.invalid");
  await command("config", "commit.gpgsign", "false");
  const git = new Git({ ...baseEnvironment(), GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" });
  const file = (path: string, value: string | Buffer) => writeFile(join(root, path), value);
  if (cleanup) t.after(() => rm(home, { recursive: true, force: true }));
  return { home, root, command, git, file };
}
const fault = (code: string) => (e: any) => e.error?.code === code;
test("Git status handles empty/nonrepos, names, rename, both sides and sensitive hints", async t => {
  const f = await fixture(t);
  assert.equal((await f.git.status(f.home)).repo, null);
  await assert.rejects(f.git.diff(f.home, "x", false, "3"), (e: any) => e.error.details.reason === "not-a-repository");
  assert.equal((await f.git.status(f.root)).repo!.headSha, null);
  await f.file("旧 文件.txt", "one\ntwo\n"); await f.file("both.txt", "old\n");
  await f.command("add", "."); await f.command("commit", "-m", "initial");
  await rename(join(f.root, "旧 文件.txt"), join(f.root, "新 文件.txt"));
  await f.file("both.txt", "staged\n"); await f.command("add", "."); await f.file("both.txt", "unstaged\n");
  for (const name of [".env", ".env.local", ".env.example", "id_rsa", "credentials.json", "normal\nfile.txt"]) await f.file(name, "fixture\n");
  const status = await f.git.status(f.root);
  assert.equal(status.repo!.branch, "main"); assert.equal(status.repo!.ahead, 0);
  const renamed = status.entries.find(e => e.path === "新 文件.txt")!;
  assert.equal(renamed.origPath, "旧 文件.txt"); assert.equal(renamed.index, "renamed");
  const both = status.entries.find(e => e.path === "both.txt")!; assert.equal(both.index, "modified"); assert.equal(both.worktree, "modified");
  assert.equal(status.entries.find(e => e.path === ".env")!.sensitiveName, true);
  assert.equal(status.entries.find(e => e.path === ".env.example")!.sensitiveName, false);
  assert.ok(status.entries.find(e => e.path === "normal\nfile.txt")?.untracked);
  await f.git.paths(f.root, { paths: ["新 文件.txt"] }, false);
  assert.equal((await f.git.status(f.root)).entries.filter(e => e.index && ["旧 文件.txt", "新 文件.txt"].includes(e.path)).length, 0);
  await f.command("checkout", "--detach"); assert.equal((await f.git.status(f.root)).repo!.branch, null);
});
test("diff full context, staged baseline, untracked, binary sizes, line and byte caps", async t => {
  const f = await fixture(t);
  const lines = Array.from({ length: 40 }, (_, i) => `line ${i}`).join("\n") + "\n";
  await f.file("text.txt", lines); await f.file("image.bin", Buffer.from([0, 1, 2]));
  await f.command("add", "."); await f.command("commit", "-m", "initial");
  await f.file("text.txt", lines.replace("line 20", "changed 20"));
  const short = await f.git.diff(f.root, "text.txt", false, "3");
  const full = await f.git.diff(f.root, "text.txt", false, "all");
  assert.equal(full.additions, 1); assert.equal(full.deletions, 1); assert.ok(full.hunks[0]!.lines.length > short.hunks[0]!.lines.length);
  assert.equal(full.hunks[0]!.lines[0]!.oldNo, 1); assert.equal(full.hunks[0]!.lines.at(-1)!.newNo, 40);
  await f.git.paths(f.root, { paths: ["text.txt"] }, true); await f.file("text.txt", lines.replace("line 20", "newer 20"));
  const staged = await f.git.diff(f.root, "text.txt", true, "all"); assert.ok(staged.hunks.flatMap(h => h.lines).some(l => l.text === "changed 20" && l.kind === "add"));
  await f.file("image.bin", Buffer.from([0, 1, 2, 3])); const binary = await f.git.diff(f.root, "image.bin", false, "all");
  assert.equal(binary.binary, true); assert.equal(binary.oldSize, 3); assert.equal(binary.newSize, 4); assert.deepEqual(binary.hunks, []);
  await f.file("untracked.txt", "first\nsecond\n"); const untracked = await f.git.diff(f.root, "untracked.txt", false, "all"); assert.equal(untracked.additions, 2);
  await f.file("huge.txt", "row\n".repeat(6000)); assert.equal((await f.git.diff(f.root, "huge.txt", false, "all")).hunks[0]!.lines.length, 5000);
  assert.equal((await f.git.diff(f.root, "huge.txt", false, "all")).truncated, true);
  await f.file("huge.txt", "x".repeat(2 * 1024 * 1024 + 100)); assert.equal((await f.git.diff(f.root, "huge.txt", false, "all")).truncated, true);
  await f.git.paths(f.root, { paths: ["huge.txt"] }, true); assert.equal((await f.git.diff(f.root, "huge.txt", true, "all")).truncated, true);
});
test("stage/unstage unborn repository, literal paths, commit/amend expected HEAD and lock protection", async t => {
  const f = await fixture(t);
  await f.file(":(glob)*.txt", "literal\n"); await f.file("other.txt", "other\n");
  await f.git.paths(f.root, { paths: [":(glob)*.txt"] }, true);
  assert.equal((await f.git.status(f.root)).entries.filter(e => e.index).length, 1);
  await f.git.paths(f.root, { paths: [":(glob)*.txt"] }, false);
  assert.equal((await f.git.status(f.root)).entries.filter(e => e.index).length, 0);
  await f.git.paths(f.root, { paths: [":(glob)*.txt", "other.txt"] }, true);
  const commit = await f.git.commit(f.root, { message: "initial", expectedHead: null }); assert.ok(commit.sha);
  await assert.rejects(f.git.commit(f.root, { message: "bad", expectedHead: null }), fault("GIT_HEAD_MOVED"));
  await f.file("other.txt", "next\n"); await f.git.paths(f.root, { paths: ["other.txt"] }, true);
  const amended = await f.git.commit(f.root, { message: "amended", amend: true, expectedHead: commit.sha }); assert.notEqual(amended.sha, commit.sha);
  assert.equal(await f.command("rev-list", "--count", "HEAD"), "1");
  await writeFile(join(f.root, ".git/index.lock"), "preserve");
  await assert.rejects(f.git.commit(f.root, { message: "locked", expectedHead: commit.sha }), fault("GIT_LOCKED"));
  assert.equal(await readFile(join(f.root, ".git/index.lock"), "utf8"), "preserve");

});
test("commit hook failure retains output and staged files; generic Git failure stays GIT_FAILED", async t => {
  const f = await fixture(t); await f.file("test.txt", "one\n"); await f.git.paths(f.root, { paths: ["test.txt"] }, true);
  await writeFile(join(f.root, ".git/hooks/pre-commit"), '#!/bin/sh\necho "fixture hook failed" >&2\nexit 1\n', { mode: 0o755 });
  await assert.rejects(f.git.commit(f.root, { message: "blocked", expectedHead: null }), (e: any) => e.error.code === "GIT_HOOK_FAILED" && e.error.details.output.includes("fixture hook failed") && !e.error.details.output.includes('"event":'));
  assert.equal((await f.git.status(f.root)).entries[0]!.index, "added");
  await rm(join(f.root, ".git/hooks/pre-commit"));
  await f.git.commit(f.root, { message: "ok", expectedHead: null });
  await assert.rejects(f.git.commit(f.root, { message: "nothing", expectedHead: (await f.git.status(f.root)).repo!.headSha }), fault("GIT_FAILED"));
});
test("stash list/apply/pop and conflicts preserve the stash", async t => {
  const f = await fixture(t); await f.file("file.txt", "base\n"); await f.command("add", "."); await f.command("commit", "-m", "base");
  await f.file("file.txt", "stashed\n"); await f.file("new.txt", "untracked\n");
  const clean = await f.git.stash(f.root, { message: "中文 stash", includeUntracked: true }); assert.equal(clean.entries.length, 0, JSON.stringify(clean.entries));
  const list = await f.git.stashes(f.root); assert.equal(list.length, 1); assert.equal(list[0]!.ref, "stash@{0}"); assert.equal(list[0]!.branch, "main");
  await f.git.apply(f.root, { ref: "stash@{0}", drop: false }); assert.equal((await f.git.stashes(f.root)).length, 1);
  await f.git.stash(f.root, { message: "second", includeUntracked: true });
  assert.equal((await f.git.stashes(f.root)).length, 2);
  await f.git.apply(f.root, { ref: "stash@{0}", drop: true });
  assert.equal((await f.git.stashes(f.root)).length, 1);
  // Commit the restored edits, then create a divergent fixture commit.
  await f.command("add", "."); await f.command("commit", "-m", "apply copy");
  await f.file("file.txt", "different\n"); await f.command("add", "."); await f.command("commit", "-m", "diverged");
  await assert.rejects(f.git.apply(f.root, { ref: "stash@{0}", drop: true }), (e: any) => e.error.code === "GIT_CONFLICT" && !!e.error.details.output);
  assert.equal((await f.git.stashes(f.root)).length, 1); assert.ok((await f.git.status(f.root)).entries.some(e => e.conflicted));
  const conflictDiff = await f.git.diff(f.root, "file.txt", false, "all");
  assert.ok(conflictDiff.hunks.some(h => h.lines.some(l => l.text.includes("<<<<<<<"))));
});
test("path containment rejects external/dangling symlinks and git missing is explicit", async t => {
  const f = await fixture(t); await writeFile(join(f.home, "outside"), "outside\n");
  await symlink(join(f.home, "outside"), join(f.root, "link")); await symlink(join(f.home, "absent"), join(f.root, "dangling"));
  for (const path of ["../outside", join(f.home, "outside"), "link", "dangling", ".git/config", "bad\0name"]) {
    await assert.rejects(f.git.diff(f.root, path, false, "3"), fault("BAD_REQUEST"));
    await assert.rejects(f.git.paths(f.root, { paths: [path] }, true), fault("BAD_REQUEST"));
  }
  await f.file("inside", "file contents\n"); await symlink("inside", join(f.root, "internal-link"));
  const linkDiff = await f.git.diff(f.root, "internal-link", false, "all");
  assert.equal(linkDiff.newSize, 6); assert.equal(linkDiff.hunks[0]!.lines[0]!.text, "inside");
  await assert.rejects(new Git({ PATH: f.home }).status(f.root), (e: any) => e.error.code === "GIT_UNAVAILABLE" && e.error.details.pathUsed === f.home);
  await assert.rejects(f.git.diff(f.root, "x", false, "1001"), fault("BAD_REQUEST"));
});
test("HTTP Git writes reject CLI and expose read routes without executing on registration", async t => {
  const f = await fixture(t, false); const server = await startServer(join(f.home, "daemon"), 0);
  t.after(async () => { await server.close(); await rm(f.home, { recursive: true, force: true }); });
  const discovery = JSON.parse(await readFile(join(f.home, "daemon/daemon.json"), "utf8"));
  const p = server.manager.register({ schemaVersion: 1, name: "Git", root: f.root, services: [{ id: "echo", name: "Echo", cwd: ".", command: ["/bin/echo", "fixture"] }] }).project;
  await f.file("hello.txt", "hello\n");
  const api = (op: string, method = "GET", data?: unknown, client = "ui") => fetch(`http://127.0.0.1:${server.httpPort}/api/v1/projects/${p.id}/git/${op}`, { method, headers: { Authorization: `Bearer ${discovery.token}`, ...(client ? { "X-DevPanel-Client": client } : {}), "Content-Type": "application/json" }, body: data === undefined ? undefined : JSON.stringify(data) });
  for (const op of ["stage", "unstage", "commit", "stash", "stash/apply"]) assert.equal((await api(op, "POST", {}, "cli")).status, 403);
  assert.equal((await api("stage", "POST", {}, "")).status, 403);
  assert.equal((await api("stage", "POST", {}, "unknown")).status, 403);
  assert.equal((await api("status")).status, 200); assert.equal((await api("diff?path=hello.txt&context=all")).status, 200);
  assert.equal((await api("stage", "POST", { paths: ["hello.txt"] })).status, 200);
  assert.equal((await api("commit", "POST", { message: "initial", expectedHead: null })).status, 200);
  assert.equal(server.manager.runs.size, 0);
});
test("status truncates at 5000 entries and reports local upstream divergence", async t => {
  const f = await fixture(t); await f.file("tracked", "base\n"); await f.command("add", "."); await f.command("commit", "-m", "base");
  const base = await f.command("rev-parse", "HEAD"); await f.command("branch", "upstream");
  await f.command("config", "branch.main.remote", "."); await f.command("config", "branch.main.merge", "refs/heads/upstream");
  await f.file("tracked", "main\n"); await f.command("add", "."); await f.command("commit", "-m", "main next");
  const other = await f.command("commit-tree", "HEAD^{tree}", "-p", base, "-m", "other next"); await f.command("update-ref", "refs/heads/upstream", other);
  const status = await f.git.status(f.root); assert.equal(status.repo!.ahead, 1); assert.equal(status.repo!.behind, 1);
  for (let i = 0; i < 5100; i += 100) await Promise.all(Array.from({ length: 100 }, (_, k) => f.file(`extra-${i + k}`, "x")));
  const large = await f.git.status(f.root); assert.equal(large.entries.length, 5000); assert.equal(large.truncated, true);
});
test("Git query timeout only signals verified fixture identities and leaves no process", async t => {
  const f = await fixture(t);
  const pidFile = join(f.home, "git-pid");
  await writeFile(join(f.home, "git"), `#!${process.execPath}\nimport fs from 'node:fs'; fs.writeFileSync(${JSON.stringify(pidFile)},String(process.pid)); setInterval(()=>{},1000);\n`, { mode: 0o755 });
  const { scanProcesses, verifiedSignal } = await import("../src/processes.ts");
  let owned: Awaited<ReturnType<typeof scanProcesses>> extends Map<number, infer R> ? R[] : never = [];
  t.after(async () => { verifiedSignal(owned, await scanProcesses(), "SIGKILL"); });
  const promise = new Git({ PATH: f.home }).status(f.root);
  for (let i = 0; i < 100; i++) { try { const pid = Number(await readFile(pidFile, "utf8")); const row = (await scanProcesses()).get(pid); if (row) { owned = [row]; break; } } catch {} await new Promise(r => setTimeout(r, 10)); }
  assert.equal(owned.length, 1);
  await assert.rejects(promise, (e: any) => e.error.code === "GIT_FAILED" && e.error.details.stderr.includes("超时"));
  for (let i = 0; i < 50 && (await scanProcesses()).get(owned[0]!.pid)?.startedAt === owned[0]!.startedAt; i++) await new Promise(r => setTimeout(r, 20));
  assert.notEqual((await scanProcesses()).get(owned[0]!.pid)?.startedAt, owned[0]!.startedAt);
});

test("HEAD moving inside a commit hook maps to GIT_HEAD_MOVED", async t => {
  const f = await fixture(t); await f.file("file.txt", "base\n"); await f.command("add", "."); await f.command("commit", "-m", "base");
  const head = (await f.git.status(f.root)).repo!.headSha!;
  const other = await f.command("commit-tree", "HEAD^{tree}", "-p", head, "-m", "external change");
  await f.file("file.txt", "staged\n"); await f.git.paths(f.root, { paths: ["file.txt"] }, true);
  await writeFile(join(f.root, ".git/hooks/pre-commit"), `#!/bin/sh\n/usr/bin/git update-ref HEAD ${other} ${head}\n`, { mode: 0o755 });
  await assert.rejects(f.git.commit(f.root, { message: "must not commit", expectedHead: head }), fault("GIT_HEAD_MOVED"));
  assert.equal((await f.git.status(f.root)).repo!.headSha, other);
});

test("diff blob fingerprints include binary and truncated tails, missing sides and symlinks", async t => {
  const f = await fixture(t);
  await f.file("binary", Buffer.from([0, 1, 2]));
  await f.file("long", "same\n".repeat(5100) + "tail A\n");
  await f.command("add", "."); await f.command("commit", "-m", "baseline");
  const before = await f.git.diff(f.root, "binary", false, "all");
  assert.equal(before.baseOid, before.newOid);
  assert.equal(before.baseOid, await f.command("rev-parse", "HEAD:binary"));
  await f.file("binary", Buffer.from([0, 1, 3]));
  const after = await f.git.diff(f.root, "binary", false, "all");
  assert.equal(after.newSize, before.newSize); assert.notEqual(after.newOid, before.newOid);
  const long = await f.git.diff(f.root, "long", false, "all");
  await f.file("long", "same\n".repeat(5100) + "tail B\n");
  const changed = await f.git.diff(f.root, "long", false, "all");
  assert.notEqual(long.newOid, changed.newOid);
  await f.file("new", "new\n"); const added = await f.git.diff(f.root, "new", false, "all");
  assert.equal(added.baseOid, null); assert.ok(added.newOid);
  await f.git.paths(f.root, { paths: ["binary"] }, true);
  const staged = await f.git.diff(f.root, "binary", true, "all");
  assert.equal(staged.baseOid, before.baseOid); assert.equal(staged.newOid, after.newOid);
  await rm(join(f.root, "binary")); assert.equal((await f.git.diff(f.root, "binary", false, "all")).newOid, null);
  await symlink("long", join(f.root, "link"));
  const link = await f.git.diff(f.root, "link", false, "all");
  await f.command("add", "link");
  assert.equal(link.newOid, await f.command("rev-parse", ":link"));
});
