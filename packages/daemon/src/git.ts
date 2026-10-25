import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { existsSync, lstatSync, readlinkSync, openSync, readSync, closeSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import type { GitStatus, GitChange, GitDiff, GitDiffLine, GitStash, GitCommitResult } from "@devpanel/contract";
import { findProgram, type BaseEnv } from "./config.ts";
import { Fault, now, sleep } from "./storage.ts";
import { discover, scanProcesses, verifiedSignal, type ProcessRow } from "./processes.ts";
const limit = 2 * 1024 * 1024;
const changes: Record<string, GitChange> = { M: "modified", A: "added", D: "deleted", R: "renamed", C: "copied", T: "typechange", U: "unmerged" };
const within = (root: string, path: string) => { const r = relative(root, path); return !isAbsolute(r) && r !== ".." && !r.startsWith("../"); };
const sensitive = (path: string) => { const n = basename(path).toLowerCase(); return ![".env.example", ".env.sample"].includes(n) && (/^\.env(?:\.|$)/.test(n) || /\.(pem|key|p12|keystore)$/.test(n) || /^(id_rsa|id_ed25519|credentials)/.test(n)); };
interface Result { code: number; stdout: Buffer; stderr: string; truncated: boolean; hookFailed: boolean }
export class Git {
  private inFlight = new Set<Promise<Result>>();
  private locks = new Map<string, Promise<unknown>>();
  private base: BaseEnv;
  private scan: () => Promise<Map<number, ProcessRow>>;
  constructor(base: BaseEnv, scan = scanProcesses) { this.base = base; this.scan = scan; }
  private async command(cwd: string, args: string[], write = false, maxBuffer = 16 * limit): Promise<Result> {
    const path = this.base.PATH || "";
    const git = findProgram("git", cwd, path);
    if (!git) throw new Fault("GIT_UNAVAILABLE", "找不到 git", 503, { pathUsed: path });
    const env = { ...this.base, LC_ALL: "C", GIT_TERMINAL_PROMPT: "0", GIT_LITERAL_PATHSPECS: args.includes("--") ? "1" : "0", ...(args[0] === "commit" ? { GIT_TRACE2_EVENT: "1" } : {}), ...(write ? {} : { GIT_OPTIONAL_LOCKS: "0" }) };
    const work = new Promise<Result>(resolve => {
      const child = spawn(git, ["--no-pager", "-c", "core.fsmonitor=false", ...args], { cwd, env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
      let known: ProcessRow[] = [], closed = false, timedOut = false, truncated = false;
      const buffers: Buffer[][] = [[], []], sizes = [0, 0];
      const collect = (index: number, data: Buffer) => {
        const remaining = maxBuffer - sizes[index]!;
        if (data.length > remaining) truncated = true;
        if (remaining > 0) { const part = data.subarray(0, remaining); buffers[index]!.push(part); sizes[index]! += part.length; }
      };
      child.stdout.on("data", data => collect(0, data)); child.stderr.on("data", data => collect(1, data));
      const observe = async () => {
        if (closed || !child.pid) return;
        try {
          const rows = await this.scan();
          if (closed) return;
          const root = rows.get(child.pid);
          if (!known.length && child.exitCode === null && child.signalCode === null && root) known = [root];
          known = discover(known, child.pid, rows);
        } catch { /* A failed identity check never authorizes a signal. */ }
      };
      child.once("spawn", () => { void observe(); });
      const started = Date.now();
      let tracking: NodeJS.Timeout;
      const track = () => { tracking = setTimeout(() => { void observe().finally(() => { if (!closed) track(); }); }, Date.now() - started < 2000 ? 50 : 250); };
      track();
      const timer = setTimeout(() => {
        timedOut = true;
        void (async () => {
          try {
            const rows = await this.scan(); const owned = discover(known, child.pid ?? null, rows);
            verifiedSignal(owned, rows, "SIGKILL");
            for (let i = 0; i < 100; i++) {
              const remaining = await this.scan();
              if (!owned.some(p => remaining.get(p.pid)?.startedAt === p.startedAt)) break;
              await sleep(20);
            }
          }
          catch { /* Preserve safety when identity cannot be verified. */ }
          finish(-1);
        })();
      }, args[0] === "commit" ? 120000 : 10000);
      child.once("error", () => finish(-1));
      child.once("close", code => { if (!timedOut) finish(code ?? -1); });
      const finish = (code: number) => {
        if (closed) return; closed = true; clearTimeout(timer); clearTimeout(tracking);
        const stdout = Buffer.concat(buffers[0]!), stderr = Buffer.concat(buffers[1]!);
        const hooks = new Set<string>(); let hookFailed = false;
        const output = (stderr || Buffer.alloc(0)).toString("utf8").split("\n").filter(line => {
          if (args[0] !== "commit" || !line.startsWith("{")) return true;
          try {
            const e = JSON.parse(line);
            if (!e.event || !e.sid) return true;
            const key = `${e.sid}/${e.child_id}`;
            if (e.event === "child_start" && e.child_class === "hook") hooks.add(key);
            if (e.event === "child_exit" && hooks.has(key) && e.code !== 0) hookFailed = true;
            return false;
          } catch { return true; }
        }).join("\n");
        resolve({ hookFailed, code: timedOut ? -1 : code, stdout, stderr: output || (timedOut ? "Git 操作超时" : ""), truncated });
      };
    });
    this.inFlight.add(work);
    try { return await work; } finally { this.inFlight.delete(work); }
  }
  async close() {
    while (this.locks.size || this.inFlight.size) await Promise.allSettled([...this.locks.values(), ...this.inFlight]);
  }
  private failure(result: Result): never { throw new Fault("GIT_FAILED", "Git 操作失败", 422, { stderr: result.stderr || "Git 查询超时或输出过大" }); }
  private async root(path: string, optional = false): Promise<string | null> {
    const r = await this.command(path, ["rev-parse", "--show-toplevel"]);
    if (r.code) { if (optional && /not a git repository/i.test(r.stderr)) return null; if (/not a git repository/i.test(r.stderr)) throw new Fault("GIT_FAILED", "项目不在 Git 工作树中", 422, { reason: "not-a-repository" }); this.failure(r); }
    return realpathSync(r.stdout.toString("utf8").replace(/\n$/, ""));
  }
  private path(root: string, input: unknown): string {
    if (typeof input !== "string" || !input || input.includes("\0") || isAbsolute(input) || input.split("/").includes("..") || input === ".") throw new Fault("BAD_REQUEST", "需要仓库内的相对文件路径");
    const full = resolve(root, input);
    if (!within(root, full)) throw new Fault("BAD_REQUEST", "路径越界");
    let check = full;
    while (!existsSync(check)) {
      // A dangling symlink still has a target and cannot bypass containment checks.
      try { if (lstatSync(check).isSymbolicLink()) throw new Fault("BAD_REQUEST", "符号链接目标无效"); } catch (e) { if (e instanceof Fault) throw e; }
      const parent = dirname(check); if (parent === check) break; check = parent;
    }
    if (!within(root, realpathSync(check))) throw new Fault("BAD_REQUEST", "符号链接指向仓库外");
    if (relative(root, full).split("/").includes(".git")) throw new Fault("BAD_REQUEST", "不能操作 Git 内部文件");
    return relative(root, full);
  }
  async status(path: string): Promise<GitStatus> {
    const root = await this.root(path, true);
    const status: GitStatus = { repo: null, entries: [], truncated: false, checkedAt: now() };
    if (!root) return status;
    const r = await this.command(root, ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]);
    if (r.code && !r.truncated) this.failure(r);
    status.truncated = r.truncated;
    const repo: NonNullable<GitStatus["repo"]> = { root, branch: null, headSha: null, upstream: null, ahead: 0, behind: 0 };
    status.repo = repo;
    const records = r.stdout.toString("utf8").split("\0");
    for (let i = 0; i < records.length; i++) {
      const line = records[i]!;
      if (line.startsWith("# branch.oid ")) { const v = line.slice(13); repo.headSha = v === "(initial)" ? null : v; continue; }
      if (line.startsWith("# branch.head ")) { const v = line.slice(14); repo.branch = v === "(detached)" ? null : v; continue; }
      if (line.startsWith("# branch.upstream ")) { repo.upstream = line.slice(18); continue; }
      if (line.startsWith("# branch.ab ")) { const m = line.match(/\+(\d+) -(\d+)/); if (m) { repo.ahead = Number(m[1]); repo.behind = Number(m[2]); } continue; }
      let file: string, xy = "..", origPath: string | null = null, conflicted = false, untracked = false;
      if (line.startsWith("? ")) { file = line.slice(2); untracked = true; }
      else if (/^[12u] /.test(line)) {
        const count = line[0] === "1" ? 8 : line[0] === "2" ? 9 : 10;
        const fields = line.split(" "); xy = fields[1]!; file = fields.slice(count).join(" ");
        if (line[0] === "2") origPath = records[++i] ?? null;
        conflicted = line[0] === "u";
      } else continue;
      if (status.entries.length >= 5000) { status.truncated = true; continue; }
      status.entries.push({ path: file, origPath, index: changes[xy[0]!] ?? null, worktree: changes[xy[1]!] ?? null, untracked, conflicted, sensitiveName: sensitive(file) });
    }
    return status;
  }
  private async size(root: string, object: string): Promise<number | null> {
    const r = await this.command(root, ["cat-file", "-s", object]); return r.code ? null : Number(r.stdout.toString());
  }
  private async oid(root: string, object: string): Promise<string | null> {
    const r = await this.command(root, ["rev-parse", "--verify", object]);
    if (!r.code) return r.stdout.toString().trim();
    return null;
  }
  private async worktreeOid(root: string, file: string): Promise<string | null> {
    try {
      if (lstatSync(join(root, file)).isSymbolicLink()) {
        const data = Buffer.from(readlinkSync(join(root, file)));
        const format = await this.command(root, ["rev-parse", "--show-object-format"]);
        if (format.code) this.failure(format);
        return createHash(format.stdout.toString().trim()).update(`blob ${data.length}\0`).update(data).digest("hex");
      }
    } catch { return null; }
    const r = await this.command(root, ["hash-object", "--no-filters", "--", file]);
    return r.code ? null : r.stdout.toString().trim();
  }
  async diff(path: string, input: unknown, staged: boolean, context: string): Promise<GitDiff> {
    const root = (await this.root(path))!; const file = this.path(root, input);
    if (context !== "all" && (!/^\d+$/.test(context) || Number(context) > 1000)) throw new Fault("BAD_REQUEST", "context 必须为 0–1000 或 all");
    const result: GitDiff = { path: file, staged, baseOid: null, newOid: null, binary: false, oldSize: null, newSize: null, truncated: false, additions: 0, deletions: 0, hunks: [] };
    const status = await this.status(root); const entry = status.entries.find(e => e.path === file);
    const original = entry?.origPath ?? file;
    result.baseOid = await this.oid(root, `${staged ? "HEAD" : ""}:${staged ? original : file}`);
    result.newOid = staged ? await this.oid(root, `:${file}`) : await this.worktreeOid(root, file);
    result.oldSize = await this.size(root, `${staged ? "HEAD" : ""}:${staged ? original : file}`);
    if (staged) result.newSize = await this.size(root, `:${file}`);
    else { try { const full = join(root, file); result.newSize = lstatSync(full).isSymbolicLink() ? Buffer.byteLength(readlinkSync(full)) : statSync(full).size; } catch {} }
    if (!staged && entry?.untracked) {
      let data: Buffer;
      if (lstatSync(join(root, file)).isSymbolicLink()) data = Buffer.from(readlinkSync(join(root, file)));
      else {
      const descriptor = openSync(join(root, file), "r");
      try { const bytes = Buffer.alloc(limit + 1); const length = readSync(descriptor, bytes, 0, bytes.length, 0); data = bytes.subarray(0, length); }
      finally { closeSync(descriptor); }
      }
      result.binary = data.subarray(0, 8000).includes(0);
      if (result.binary) return result;
      const lines = data.subarray(0, limit).toString("utf8").split("\n"); if (lines.at(-1) === "") lines.pop();
      result.truncated = data.length > limit || lines.length > 5000;
      const visible = lines.slice(0, 5000); result.additions = visible.length;
      result.hunks = [{ header: `@@ -0,0 +1,${visible.length} @@`, lines: visible.map((text, i) => ({ kind: "add", text, oldNo: null, newNo: i + 1 })) }];
      return result;
    }
    if (entry?.conflicted && staged) {
      result.hunks = [{ header: "未合并的暂存区", lines: [{ kind: "meta", text: "文件存在冲突，暂存区尚无合并结果；请查看未暂存差异。", oldNo: null, newNo: null }] }];
      return result;
    }
    const args = ["diff", ...(entry?.conflicted ? ["--ours"] : []), "--no-ext-diff", "--no-textconv", "--no-color", `--unified=${context === "all" ? 2147483647 : context}`, ...(staged ? ["--cached"] : []), "--", file];
    if (entry?.origPath && staged) args.push(entry.origPath);
    const r = await this.command(root, args, false, limit + 65536);
    if (r.code && !r.truncated) this.failure(r);
    result.truncated = r.truncated || r.stdout.length > limit;
    const patch = r.stdout.subarray(0, limit).toString("utf8");
    result.binary = /^Binary files .* differ$/m.test(patch) || /^GIT binary patch$/m.test(patch);
    if (result.binary) return result;
    let oldNo = 0, newNo = 0, count = 0;
    let hunk: GitDiff["hunks"][number] | undefined;
    for (const line of patch.split("\n")) {
      if (line.startsWith("diff --git ")) { hunk = undefined; continue; }
      const header = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
      if (header) { oldNo = Number(header[1]); newNo = Number(header[2]); hunk = { header: line, lines: [] }; result.hunks.push(hunk); continue; }
      if (!hunk || !/^[ +\\-]/.test(line)) continue;
      if (count++ >= 5000) { result.truncated = true; break; }
      let row: GitDiffLine;
      if (line[0] === "+") { row = { kind: "add", text: line.slice(1), oldNo: null, newNo: newNo++ }; result.additions++; }
      else if (line[0] === "-") { row = { kind: "del", text: line.slice(1), oldNo: oldNo++, newNo: null }; result.deletions++; }
      else if (line[0] === " ") row = { kind: "context", text: line.slice(1), oldNo: oldNo++, newNo: newNo++ };
      else row = { kind: "meta", text: line, oldNo: null, newNo: null };
      hunk.lines.push(row);
    }
    return result;
  }
  private async write<T>(path: string, action: (root: string) => Promise<T>): Promise<T> {
    const root = (await this.root(path))!;
    const previous = this.locks.get(root) ?? Promise.resolve();
    const work = previous.catch(() => {}).then(async () => {
      const lock = await this.command(root, ["rev-parse", "--git-path", "index.lock"]);
      if (lock.code) this.failure(lock);
      if (existsSync(resolve(root, lock.stdout.toString().replace(/\n$/, "")))) throw new Fault("GIT_LOCKED", "Git index.lock 已存在；请等待其他 Git 操作完成", 409, { stderr: "index.lock exists" });
      return action(root);
    });
    this.locks.set(root, work);
    try { return await work; } finally { if (this.locks.get(root) === work) this.locks.delete(root); }
  }
  private checkWrite(r: Result) {
    if (!r.code) return;
    if (/index\.lock.*(?:exists|File exists)|Unable to create .*index\.lock/s.test(r.stderr)) throw new Fault("GIT_LOCKED", "Git 索引被锁定", 409, { stderr: r.stderr });
    this.failure(r);
  }
  async paths(path: string, input: unknown, stage: boolean): Promise<GitStatus> {
    return this.write(path, async root => {
      const paths = (input as any)?.paths;
      if (!Array.isArray(paths) || !paths.length || paths.length > 5000) throw new Fault("BAD_REQUEST", "paths 必须是非空路径数组");
      const requested = paths.map(p => this.path(root, p));
      const status = await this.status(root);
      // A rename is one file operation in the UI, but both index paths must move together.
      const files = [...new Set(requested.flatMap(file => {
        const original = status.entries.find(entry => entry.path === file)?.origPath;
        return original ? [file, this.path(root, original)] : [file];
      }))];
      const args = stage ? ["add", "--", ...files] : status.repo?.headSha ? ["reset", "-q", "HEAD", "--", ...files] : ["rm", "--cached", "-r", "--ignore-unmatch", "--", ...files];
      this.checkWrite(await this.command(root, args, true)); return this.status(root);
    });
  }
  async commit(path: string, input: unknown): Promise<GitCommitResult> {
    return this.write(path, async root => {
      const r = input as any;
      if (!r || typeof r.message !== "string" || !r.message.trim() || r.message.includes("\0") || (r.amend !== undefined && typeof r.amend !== "boolean") || !(r.expectedHead === null || typeof r.expectedHead === "string" && /^[a-f0-9]{40,64}$/.test(r.expectedHead))) throw new Fault("BAD_REQUEST", "提交信息或 expectedHead 无效");
      const status = await this.status(root);
      if (status.repo!.headSha !== r.expectedHead) throw new Fault("GIT_HEAD_MOVED", "HEAD 已变化，请刷新并重新确认", 409, { expectedHead: r.expectedHead, actualHead: status.repo!.headSha });
      const result = await this.command(root, ["commit", ...(r.amend ? ["--amend"] : []), "-m", r.message], true);
      if (result.code) {
        const current = await this.status(root);
        if (current.repo!.headSha !== r.expectedHead) throw new Fault("GIT_HEAD_MOVED", "提交期间 HEAD 已变化，请刷新并重新确认", 409, { expectedHead: r.expectedHead, actualHead: current.repo!.headSha });
        if (/index\.lock/.test(result.stderr)) this.checkWrite(result);
        const output = result.stdout.toString() + result.stderr;
        if (result.hookFailed) throw new Fault("GIT_HOOK_FAILED", "提交未完成，请检查钩子输出", 422, { output });
        this.failure(result);
      }
      const after = await this.status(root);
      return { sha: after.repo!.headSha!, output: result.stdout.toString() + result.stderr };
    });
  }
  async stashes(path: string): Promise<GitStash[]> {
    const root = (await this.root(path))!;
    const r = await this.command(root, ["stash", "list", "--format=%gd%x00%gs%x00%cI%x00"]);
    if (r.code) this.failure(r);
    const parts = r.stdout.toString().split("\0"); const result: GitStash[] = [];
    for (let i = 0; i + 2 < parts.length; i += 3) { const ref = parts[i]!.replace(/^\n/, ""); if (!ref) continue; const message = parts[i + 1]!; result.push({ ref, message, branch: /^(?:On|WIP on) (.*?):/.exec(message)?.[1] ?? null, createdAt: parts[i + 2]! }); }
    return result;
  }
  async stash(path: string, input: unknown): Promise<GitStatus> {
    return this.write(path, async root => {
      const r = input as any;
      if (!r || typeof r !== "object" || (r.message !== undefined && (typeof r.message !== "string" || r.message.includes("\0"))) || (r.includeUntracked !== undefined && typeof r.includeUntracked !== "boolean")) throw new Fault("BAD_REQUEST", "储藏参数无效");
      this.checkWrite(await this.command(root, ["stash", "push", ...(r.includeUntracked ? ["--include-untracked"] : []), ...(r.message ? ["-m", r.message] : [])], true));
      return this.status(root);
    });
  }
  async apply(path: string, input: unknown): Promise<GitStatus> {
    return this.write(path, async root => {
      const r = input as any;
      if (!r || typeof r.ref !== "string" || !/^stash@\{\d+\}$/.test(r.ref) || typeof r.drop !== "boolean") throw new Fault("BAD_REQUEST", "储藏引用或 drop 无效");
      const result = await this.command(root, ["stash", r.drop ? "pop" : "apply", r.ref], true);
      if (result.code) {
        const status = await this.status(root);
        if (status.entries.some(e => e.conflicted)) throw new Fault("GIT_CONFLICT", "恢复储藏发生冲突；储藏已保留", 409, { output: result.stdout.toString() + result.stderr });
        this.checkWrite(result);
      }
      return this.status(root);
    });
  }
}
