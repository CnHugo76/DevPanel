import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { GitEntry } from '@devpanel/contract';
import { MockGit, sensitiveName } from '../src/git.ts';
import { HttpError } from '../src/errors.ts';
import { Engine } from '../src/engine.ts';
import { seed } from '../src/seed.ts';
import { createMockServer } from '../src/server.ts';
const repo = () => new MockGit('/virtual/order-service', true);
const code = (expected: string, status?: number) => (e: unknown) => e instanceof HttpError && e.error.code === expected && (status === undefined || e.status === status);
const resolveConflicts = (g: MockGit) => g.stage({ paths: g.status().entries.filter(e => e.conflicted).map(e => e.path) });

test('Git seed has all groups, sensitive file, binary sizes and two stashes; non-repo and unavailable', () => {
  const g = repo(), status = g.status();
  assert.equal(status.repo?.branch, 'main'); assert.equal(status.repo?.ahead, 2); assert.equal(status.repo?.behind, 1);
  for (const predicate of [(e: GitEntry) => e.index && !e.conflicted, (e: GitEntry) => e.worktree && !e.conflicted, (e: GitEntry) => e.untracked, (e: GitEntry) => e.conflicted]) assert.ok(status.entries.some(predicate));
  assert.ok(status.entries.find(e => e.path === '.env.local')?.sensitiveName);
  assert.equal(g.stashes().length, 2);
  assert.deepEqual(new MockGit('/virtual/not-repo').status().repo, null);
  assert.throws(() => new MockGit('/virtual/not-repo').diff('file', false), e => code('GIT_FAILED', 422)(e) && (e as HttpError).error.details?.reason === 'not-a-repository');
  g.configure({ unavailable: true });
  assert.throws(() => g.status(), e => code('GIT_UNAVAILABLE', 503)(e) && typeof (e as HttpError).error.details?.pathUsed === 'string');
  for (const f of ['.env', '.env.local', 'config/private.pem', 'id_ed25519.pub', 'credentials.json', 'cert.p12', 'x.keystore']) assert.equal(sensitiveName(f), true, f);
  for (const f of ['.env.example', '.env.sample', 'README.md']) assert.equal(sensitiveName(f), false, f);
});

test('diff respects index/worktree sides, finite/all context, binary and 5000-line truncation', () => {
  const g = repo();
  const diff = g.diff('backend/src/OrderService.java', false, 3);
  assert.equal(diff.additions, 2); assert.equal(diff.deletions, 2); assert.equal(diff.hunks.length, 2);
  assert.ok(diff.hunks[0]!.lines.some(l => l.kind === 'del' && l.oldNo === 4 && l.newNo === null));
  const all = g.diff('backend/src/OrderService.java', false, 'all');
  assert.equal(all.hunks.length, 1); assert.equal(all.hunks[0]!.lines.filter(l => l.newNo !== null).length, 36);
  assert.equal(g.diff('README.md', false).hunks.length, 0);
  assert.equal(g.diff('README.md', true).additions, 1);
  assert.equal(g.diff('notes/new-feature.md', false).deletions, 0);
  assert.equal(g.diff('notes/new-feature.md', false).additions, 2);
  const binary = g.diff('assets/logo.png', false, 'all');
  assert.equal(binary.binary, true); assert.deepEqual(binary.hunks, []); assert.equal(binary.oldSize, 12 * 1024); assert.equal(binary.newSize, 14 * 1024);
  const large = g.diff('large.txt', false, 'all');
  assert.equal(large.truncated, true); assert.equal(large.hunks[0]!.lines.length, 5000);
  assert.equal(g.diff('large.txt', false, 3).truncated, false);
  for (const context of [-1, 1001, 1.1]) assert.throws(() => g.diff('README.md', true, context), code('BAD_REQUEST', 400));
});

test('paths are contained and stage/unstage is atomic and transitions tracked/untracked/conflicted groups', () => {
  const g = repo();
  for (const p of ['/etc/passwd', '../outside', 'backend/../../outside', 'C:\\secret', 'outside-link/file', 'a\0b']) {
    assert.throws(() => g.stage({ paths: [p] }), code('BAD_REQUEST', 400));
    assert.throws(() => g.diff(p, false), code('BAD_REQUEST', 400));
  }
  assert.throws(() => g.stage({ paths: ['notes/new-feature.md', '../bad'] }), code('BAD_REQUEST'));
  assert.ok(g.status().entries.find(e => e.path === 'notes/new-feature.md')?.untracked);
  g.stage({ paths: ['notes/new-feature.md', 'backend/src/OrderService.java'] });
  assert.equal(g.status().entries.find(e => e.path === 'notes/new-feature.md')?.index, 'added');
  assert.equal(g.diff('backend/src/OrderService.java', false).hunks.length, 0);
  assert.equal(g.diff('backend/src/OrderService.java', true).additions, 2);
  g.stage({ paths: ['notes/new-feature.md', 'backend/src/OrderService.java'] }, true);
  assert.ok(g.status().entries.find(e => e.path === 'notes/new-feature.md')?.untracked);
  resolveConflicts(g); assert.ok(g.status().entries.every(e => !e.conflicted));
});

test('commit protects expected HEAD, preserves lock/hook failures, updates only staged data and supports amend', () => {
  const g = repo(); resolveConflicts(g);
  const head = g.status().repo!.headSha;
  g.configure({ locked: true });
  assert.throws(() => g.commit({ expectedHead: head, message: 'test' }), code('GIT_LOCKED', 409));
  assert.equal(g.modes.locked, true);
  g.configure({ locked: false, hookFailure: true });
  assert.throws(() => g.commit({ expectedHead: head, message: 'test' }), e => code('GIT_HOOK_FAILED', 422)(e) && String((e as HttpError).error.details?.output).includes('pre-commit'));
  assert.equal(g.status().repo!.headSha, head);
  g.configure({ hookFailure: false, headMoved: true });
  assert.throws(() => g.commit({ expectedHead: head, message: 'test' }), code('GIT_HEAD_MOVED', 409));
  const result = g.commit({ expectedHead: g.status().repo!.headSha, message: 'Commit staged changes' });
  assert.equal(result.sha.length, 40);
  assert.ok(g.status().entries.every(e => e.index === null));
  assert.ok(g.status().entries.some(e => e.untracked));
  const amended = g.commit({ expectedHead: result.sha, message: 'Amended message', amend: true });
  assert.notEqual(amended.sha, result.sha);
});

test('stash includeUntracked, apply/pop and conflict preservation', () => {
  const g = repo(); resolveConflicts(g);
  const initial = g.stashes().length;
  const remaining = g.stash({ message: 'Save tracked edits' });
  assert.ok(remaining.entries.every(e => e.untracked));
  assert.equal(g.stashes().length, initial + 1);
  g.apply({ ref: 'stash@{0}', drop: false }); assert.equal(g.stashes().length, initial + 1);
  g.stash({ message: 'Save everything', includeUntracked: true });
  assert.equal(g.status().entries.length, 0);
  const before = g.stashes().length;
  g.configure({ stashConflict: true });
  assert.throws(() => g.apply({ ref: 'stash@{0}', drop: true }), e => code('GIT_CONFLICT', 409)(e) && String((e as HttpError).error.details?.output).includes('kept'));
  assert.equal(g.stashes().length, before);
  assert.ok(g.status().entries.some(e => e.conflicted));
  const clean = repo(); clean.configure({ reset: true });
  const count = clean.stashes().length;
  clean.apply({ ref: 'stash@{0}', drop: true }); assert.equal(clean.stashes().length, count - 1);
  assert.equal(clean.stashes()[0]!.ref, 'stash@{0}');
});

test('Git HTTP routes require ui writes, validate diff arguments and expose deterministic debug modes', async t => {
  const e = new Engine('/tmp/dp-mock-git'); seed(e); t.after(() => e.stop());
  const { server } = createMockServer({ engine: e, port: 0, token: 'test', uiDir: null, log() {} });
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  t.after(async () => { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); });
  const port = (server.address() as import('node:net').AddressInfo).port;
  const call = (route: string, method = 'GET', data?: unknown, client: string | null = 'ui') => fetch(`http://127.0.0.1:${port}${route}`, { method, headers: { authorization: 'Bearer test', 'content-type': 'application/json', ...(client ? { 'x-devpanel-client': client } : {}) }, ...(data === undefined ? {} : { body: JSON.stringify(data) }) });
  const base = '/api/v1/projects/p_ordersvc2a/git';
  assert.equal((await call(`${base}/status`)).status, 200);
  assert.equal((await call(`${base}/diff?path=README.md&staged=true&context=all`)).status, 200);
  for (const suffix of ['staged=1', 'context=1001', 'context=-1']) assert.equal((await call(`${base}/diff?path=README.md&${suffix}`)).status, 400);
  for (const op of ['stage', 'unstage', 'commit', 'stash', 'stash/apply']) for (const client of ['cli', null]) assert.equal((await call(`${base}/${op}`, 'POST', {}, client)).status, 403);
  assert.equal((await call(`${base}/stage`, 'POST', { paths: ['notes/new-feature.md'] })).status, 200);
  assert.equal((await call(`${base}/unstage`, 'POST', { paths: ['notes/new-feature.md'] })).status, 200);
  assert.equal((await call(`${base}/stashes`)).status, 200);
  assert.equal((await call('/__mock/git/p_ordersvc2a', 'POST', { locked: true })).status, 200);
  assert.equal((await call(`${base}/stage`, 'POST', { paths: ['README.md'] })).status, 409);
  await call('/__mock/git/p_ordersvc2a', 'POST', { reset: true, unavailable: true });
  assert.equal((await call(`${base}/status`)).status, 503);
  const notRepo = await call('/api/v1/projects/p_mlapi22222/git/status');
  assert.equal((await notRepo.json() as { repo: null }).repo, null);
});
