/** In-memory Git fixture. Never invokes git or reads/writes a project directory. */
import path from 'node:path';
import { createHash } from 'node:crypto';
import type { GitChange, GitDiff, GitDiffLine, GitEntry, GitStash, GitStatus } from '@devpanel/contract';
import { HttpError, badRequest } from './errors.ts';
import { iso } from './util.ts';

type File = { text: string | null; bytes: number };
type Tree = Map<string, File>;
type Stash = { info: GitStash; changes: Map<string, File | null> };
export interface GitModes { locked: boolean; hookFailure: boolean; stashConflict: boolean; unavailable: boolean; }
const textFile = (text: string): File => ({ text, bytes: Buffer.byteLength(text) });
const same = (a: File | undefined, b: File | undefined) => a === b || (a?.text === b?.text && a?.bytes === b?.bytes);
const blobOid = (file: File | undefined) => {
  if (!file) return null;
  const data = file.text === null ? Buffer.alloc(file.bytes) : Buffer.from(file.text);
  return createHash('sha1').update(`blob ${data.length}\0`).update(data).digest('hex');
};
const cloneTree = (tree: Tree): Tree => structuredClone(tree);
const change = (before: File | undefined, after: File | undefined): GitChange | null => same(before, after) ? null : !before ? 'added' : !after ? 'deleted' : 'modified';
const obj = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value);
const failure = (message: string, stderr = message): never => { throw new HttpError(422, 'GIT_FAILED', message, { stderr }); };
export function sensitiveName(file: string): boolean {
  const name = path.posix.basename(file);
  if (name === '.env.example' || name === '.env.sample') return false;
  return name === '.env' || name.startsWith('.env.') || /\.(pem|key|p12|keystore)$/.test(name) || /^(id_rsa|id_ed25519|credentials)/.test(name);
}

export class MockGit {
  readonly modes: GitModes = { locked: false, hookFailure: false, stashConflict: false, unavailable: false };
  readonly externalLinks = new Set(['outside-link']);
  private head: Tree = new Map();
  private index: Tree = new Map();
  private work: Tree = new Map();
  private conflicts = new Set<string>();
  private saved: Stash[] = [];
  private revision = 1;
  private repo: GitStatus['repo'] = null;
  private root: string;
  constructor(root: string, seeded = false) { this.root = root; if (seeded) this.reset(); }

  reset(): void {
    Object.assign(this.modes, { locked: false, hookFailure: false, stashConflict: false, unavailable: false });
    this.repo = { root: this.root, branch: 'main', headSha: '1'.repeat(40), upstream: 'origin/main', ahead: 2, behind: 1 };
    const source = Array.from({ length: 36 }, (_, i) => i === 3 ? '  return order.total;' : i === 24 ? 'const currency = "USD";' : `// Order processing line ${i + 1}`).join('\n') + '\n';
    this.head = new Map([
      ['backend/src/OrderService.java', textFile(source)],
      ['README.md', textFile('# Order Service\n\nRun the backend locally.\n')],
      ['backend/src/Conflict.java', textFile('class Conflict {\n  int version = 1;\n}\n')],
      ['assets/logo.png', { text: null, bytes: 12 * 1024 }],
      ['large.txt', textFile(Array.from({ length: 5100 }, (_, i) => `line ${i}`).join('\n') + '\n')],
    ]);
    this.index = cloneTree(this.head); this.work = cloneTree(this.head);
    this.index.set('README.md', textFile('# Order Service\n\nRun the backend with DevPanel.\n'));
    this.work.set('README.md', this.index.get('README.md')!);
    this.work.set('backend/src/OrderService.java', textFile(source.replace('order.total;', 'order.totalWithTax();').replace('"USD"', '"CNY"')));
    this.work.set('.env.local', textFile('API_URL=http://127.0.0.1:8080\nDEMO_SETTING=placeholder\n'));
    this.work.set('notes/new-feature.md', textFile('# New feature\nA local draft.\n'));
    this.work.set('assets/logo.png', { text: null, bytes: 14 * 1024 });
    this.work.set('large.txt', textFile(this.head.get('large.txt')!.text!.replace('line 2500\n', 'changed line 2500\n')));
    this.work.set('backend/src/Conflict.java', textFile('class Conflict {\n<<<<<<< Updated upstream\n  int version = 2;\n=======\n  int version = 3;\n>>>>>>> Stashed changes\n}\n'));
    this.conflicts = new Set(['backend/src/Conflict.java']);
    this.saved = [
      { info: { ref: 'stash@{0}', message: 'WIP on main: order validation', branch: 'main', createdAt: iso(Date.now() - 3600_000) }, changes: new Map([['backend/src/Validation.java', textFile('class Validation { boolean enabled = true; }\n')]]) },
      { info: { ref: 'stash@{1}', message: 'On feature/payment: payment draft', branch: 'feature/payment', createdAt: iso(Date.now() - 86400_000) }, changes: new Map([['backend/src/Payment.java', textFile('class Payment { int retries = 3; }\n')]]) },
    ];
  }

  configure(input: unknown): void {
    if (!obj(input)) throw badRequest('Git mock 配置必须是对象');
    for (const [key, value] of Object.entries(input)) {
      if (!['reset', 'headMoved', 'notRepository', ...Object.keys(this.modes)].includes(key) || typeof value !== 'boolean') throw badRequest(`无效 mock 选项：${key}`);
    }
    if (input.reset) this.reset();
    if (input.notRepository === true) this.repo = null;
    if (input.headMoved && this.repo) this.repo.headSha = this.nextSha('external commit');
    for (const key of Object.keys(this.modes) as (keyof GitModes)[]) if (typeof input[key] === 'boolean') this.modes[key] = input[key];
  }

  private available(requireRepo = true): void {
    if (this.modes.unavailable) throw new HttpError(503, 'GIT_UNAVAILABLE', '找不到 git', { pathUsed: '/mock/bin' });
    if (requireRepo && !this.repo) throw new HttpError(422, 'GIT_FAILED', '项目不在 Git 仓库中', { reason: 'not-a-repository' });
  }
  private writable(): void {
    this.available();
    if (this.modes.locked) throw new HttpError(409, 'GIT_LOCKED', 'Git 索引被锁定', { stderr: "fatal: Unable to create '.git/index.lock': File exists." });
  }
  private filePath(value: unknown): string {
    if (typeof value !== 'string' || !value || value.includes('\0') || value.includes('\\') || path.posix.isAbsolute(value) || /^[A-Za-z]:/.test(value)) throw badRequest('路径必须是仓库内相对路径');
    const normalized = path.posix.normalize(value);
    if (normalized === '.' || normalized === '..' || normalized.startsWith('../') || value.split('/').includes('..')) throw badRequest('路径不能越出仓库');
    if ([...this.externalLinks].some(link => normalized === link || normalized.startsWith(link + '/'))) throw badRequest('符号链接指向仓库外');
    return normalized;
  }
  private paths(input: unknown): string[] {
    if (!obj(input) || !Array.isArray(input.paths) || !input.paths.length) throw badRequest('paths 必须是非空数组');
    return [...new Set(input.paths.map(p => this.filePath(p)))];
  }
  private nextSha(message: string) { return createHash('sha1').update(`${this.repo?.headSha}:${++this.revision}:${message}`).digest('hex'); }

  status(): GitStatus {
    this.available(false);
    if (!this.repo) return { repo: null, entries: [], truncated: false, checkedAt: iso() };
    const entries: GitEntry[] = [];
    for (const file of new Set([...this.head.keys(), ...this.index.keys(), ...this.work.keys(), ...this.conflicts])) {
      const h = this.head.get(file), i = this.index.get(file), w = this.work.get(file);
      const conflicted = this.conflicts.has(file);
      const untracked = !h && !i && !!w;
      const index = conflicted ? 'unmerged' : change(h, i);
      const worktree = conflicted ? 'unmerged' : untracked ? null : change(i, w);
      if (index || worktree || untracked || conflicted) entries.push({ path: file, origPath: null, index, worktree, untracked, conflicted, sensitiveName: sensitiveName(file) });
    }
    return { repo: structuredClone(this.repo), entries: entries.slice(0, 5000), truncated: entries.length > 5000, checkedAt: iso() };
  }

  diff(file: unknown, staged: boolean, context: number | 'all' = 3): GitDiff {
    this.available();
    const name = this.filePath(file);
    if (typeof staged !== 'boolean' || (context !== 'all' && (!Number.isInteger(context) || context < 0 || context > 1000))) throw badRequest('无效 staged 或 context');
    const before = (staged ? this.head : this.index).get(name);
    const after = (staged ? this.index : this.work).get(name);
    if (!before && !after) return failure('文件不存在');
    const binary = before?.text === null || after?.text === null;
    const result: GitDiff = { path: name, staged, baseOid: blobOid(before), newOid: blobOid(after), binary, oldSize: before?.bytes ?? 0, newSize: after?.bytes ?? 0, truncated: false, additions: 0, deletions: 0, hunks: [] };
    if (binary || same(before, after)) return result;
    const split = (f: File | undefined) => { if (!f?.text) return []; const lines = f.text.split('\n'); if (lines.at(-1) === '') lines.pop(); return lines; };
    const a = split(before), b = split(after);
    const lines = diffLines(a, b);
    result.additions = lines.filter(l => l.kind === 'add').length; result.deletions = lines.filter(l => l.kind === 'del').length;
    const groups: [number, number][] = [];
    if (context === 'all') groups.push([0, lines.length]);
    else lines.forEach((line, i) => {
      if (line.kind === 'context') return;
      const start = Math.max(0, i - context), end = Math.min(lines.length, i + context + 1), previous = groups.at(-1);
      if (previous && start <= previous[1]) previous[1] = Math.max(previous[1], end); else groups.push([start, end]);
    });
    let count = 0, bytes = 0;
    for (const [start, end] of groups) {
      const selected: GitDiffLine[] = [];
      for (const line of lines.slice(start, end)) {
        bytes += Buffer.byteLength(line.text); count++;
        if (count > 5000 || bytes > 2 * 1024 * 1024) { result.truncated = true; break; }
        selected.push(line);
      }
      const oldLines = selected.filter(l => l.oldNo !== null), newLines = selected.filter(l => l.newNo !== null);
      if (selected.length) result.hunks.push({ header: `@@ -${oldLines[0]?.oldNo ?? 0},${oldLines.length} +${newLines[0]?.newNo ?? 0},${newLines.length} @@`, lines: selected });
      if (result.truncated) break;
    }
    return result;
  }

  stage(input: unknown, unstage = false): GitStatus {
    this.writable(); const paths = this.paths(input);
    for (const file of paths) if (!this.head.has(file) && !this.index.has(file) && !this.work.has(file)) failure(`pathspec '${file}' did not match any files`);
    for (const file of paths) {
      const value = (unstage ? this.head : this.work).get(file);
      if (value) this.index.set(file, structuredClone(value)); else this.index.delete(file);
      if (!unstage) this.conflicts.delete(file);
    }
    return this.status();
  }

  commit(input: unknown) {
    this.writable();
    if (!obj(input) || typeof input.message !== 'string' || !input.message.trim() || (input.expectedHead !== null && typeof input.expectedHead !== 'string') || (input.amend !== undefined && typeof input.amend !== 'boolean')) throw badRequest('无效提交请求');
    if (input.expectedHead !== this.repo!.headSha) throw new HttpError(409, 'GIT_HEAD_MOVED', 'HEAD 已变化，请刷新后重新确认', { expectedHead: input.expectedHead, actualHead: this.repo!.headSha });
    if (this.conflicts.size) return failure('存在冲突文件，无法提交');
    if (this.modes.hookFailure) throw new HttpError(422, 'GIT_HOOK_FAILED', '提交钩子失败', { output: 'pre-commit: checking staged files\nERROR: simulated lint failure\nCommit aborted.\n' });
    if (!input.amend && ![...new Set([...this.head.keys(), ...this.index.keys()])].some(p => !same(this.head.get(p), this.index.get(p)))) return failure('没有已暂存的改动');
    const sha = this.nextSha(input.message);
    this.head = cloneTree(this.index); this.repo!.headSha = sha;
    if (this.repo!.upstream && !input.amend) this.repo!.ahead++;
    return { sha, output: `[${this.repo!.branch ?? 'detached HEAD'} ${sha.slice(0, 7)}] ${input.message.split('\n')[0]}\n` };
  }

  stashes(): GitStash[] { this.available(); return this.saved.map((s, i) => ({ ...s.info, ref: `stash@{${i}}` })); }
  stash(input: unknown): GitStatus {
    this.writable();
    if (!obj(input) || (input.message !== undefined && typeof input.message !== 'string') || (input.includeUntracked !== undefined && typeof input.includeUntracked !== 'boolean')) throw badRequest('无效储藏请求');
    if (this.conflicts.size) return failure('存在冲突文件，无法储藏');
    const changes = new Map<string, File | null>();
    for (const file of new Set([...this.head.keys(), ...this.index.keys(), ...this.work.keys()])) {
      if (!this.head.has(file) && !this.index.has(file) && !input.includeUntracked) continue;
      if (!same(this.head.get(file), this.work.get(file)) || !same(this.head.get(file), this.index.get(file))) changes.set(file, structuredClone(this.work.get(file) ?? null));
    }
    if (!changes.size) return this.status();
    this.saved.unshift({ info: { ref: 'stash@{0}', message: typeof input.message === 'string' && input.message ? input.message : `WIP on ${this.repo!.branch ?? 'detached HEAD'}`, branch: this.repo!.branch, createdAt: iso() }, changes });
    this.index = cloneTree(this.head);
    for (const file of changes.keys()) { const original = this.head.get(file); if (original) this.work.set(file, structuredClone(original)); else this.work.delete(file); }
    return this.status();
  }
  apply(input: unknown): GitStatus {
    this.writable();
    if (!obj(input) || typeof input.ref !== 'string' || !/^stash@\{\d+\}$/.test(input.ref) || typeof input.drop !== 'boolean') throw badRequest('无效储藏恢复请求');
    const n = Number(input.ref.slice(7, -1)), stash = this.saved[n];
    if (!stash) return failure('储藏不存在');
    const conflicts = [...stash.changes].filter(([file, value]) => this.modes.stashConflict || (!same(this.work.get(file), this.head.get(file)) && !same(this.work.get(file), value ?? undefined)));
    if (conflicts.length) {
      for (const [file, value] of conflicts) {
        this.conflicts.add(file);
        const current = this.work.get(file);
        if (current?.text !== null && value?.text !== null) this.work.set(file, textFile(`<<<<<<< Updated upstream\n${current?.text ?? ''}=======\n${value?.text ?? ''}>>>>>>> Stashed changes\n`));
        else if (!current && value) this.work.set(file, structuredClone(value));
      }
      throw new HttpError(409, 'GIT_CONFLICT', '恢复储藏发生冲突，储藏已保留', { output: `CONFLICT (content): Merge conflict in ${conflicts.map(([file]) => file).join(', ')}\nThe stash entry is kept.\n` });
    }
    for (const [file, value] of stash.changes) if (value) this.work.set(file, structuredClone(value)); else this.work.delete(file);
    if (input.drop) this.saved.splice(n, 1);
    return this.status();
  }
}

/** LCS for small changed sections, bounded fallback for large replacement blocks. */
function diffLines(a: string[], b: string[]): GitDiffLine[] {
  let prefix = 0, suffix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] === b[prefix]) prefix++;
  while (suffix < a.length - prefix && suffix < b.length - prefix && a[a.length - suffix - 1] === b[b.length - suffix - 1]) suffix++;
  const aa = a.slice(prefix, a.length - suffix), bb = b.slice(prefix, b.length - suffix);
  const output: GitDiffLine[] = []; let oldNo = 1, newNo = 1;
  const push = (kind: GitDiffLine['kind'], text: string) => output.push({ kind, text, oldNo: kind === 'add' ? null : oldNo++, newNo: kind === 'del' ? null : newNo++ });
  a.slice(0, prefix).forEach(line => push('context', line));
  if (aa.length * bb.length <= 1_000_000) {
    const dp = Array.from({ length: aa.length + 1 }, () => new Uint32Array(bb.length + 1));
    for (let i = aa.length - 1; i >= 0; i--) for (let j = bb.length - 1; j >= 0; j--) dp[i]![j] = aa[i] === bb[j] ? dp[i + 1]![j + 1]! + 1 : Math.max(dp[i + 1]![j]!, dp[i]![j + 1]!);
    let i = 0, j = 0;
    while (i < aa.length || j < bb.length) {
      if (i < aa.length && j < bb.length && aa[i] === bb[j]) { push('context', aa[i++]!); j++; }
      else if (i < aa.length && (j === bb.length || dp[i + 1]![j]! >= dp[i]![j + 1]!)) push('del', aa[i++]!);
      else push('add', bb[j++]!);
    }
  } else { aa.forEach(line => push('del', line)); bb.forEach(line => push('add', line)); }
  a.slice(a.length - suffix).forEach(line => push('context', line));
  return output;
}
