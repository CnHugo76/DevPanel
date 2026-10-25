import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { LogLine } from '@devpanel/contract';
import { searchLogs } from '../src/log-search.ts';

const line = (seq: number, text: string): LogLine => ({ seq, text, stream: 'out', ts: '2026-10-25T00:00:00.000Z' });
test('retained search finds old ANSI/Unicode literal matches outside the loaded tail', () => {
  const lines = Array.from({ length: 10000 }, (_, i) => line(i + 1, i === 2 ? '\x1b[31mERROR 中文 [a.*]\x1b[0m' : 'normal'));
  const page = searchLogs('r', lines, false, new URLSearchParams({ q: 'error 中文 [a.*]', context: '2' }));
  assert.equal(page.throughSeq, 10000);
  assert.equal(page.scannedThroughSeq, 10000);
  assert.equal(page.hasMore, false);
  assert.deepEqual(page.matches.map(m => [m.before.map(l => l.seq), m.line.seq, m.after.map(l => l.seq)]), [[[1, 2], 3, [4, 5]]]);
  assert.match(page.matches[0]!.line.text, /\x1b/);
  assert.equal(searchLogs('r', lines, false, new URLSearchParams({ q: 'error', caseSensitive: 'true' })).matches.length, 0);
});

test('pagination freezes the upper sequence, bounds context and exposes retention loss', () => {
  const lines = [line(10, 'match'), line(11, 'context'), line(12, 'match'), line(13, 'context')];
  const first = searchLogs('r', lines, true, new URLSearchParams({ q: 'match', limit: '1', context: '5' }));
  assert.equal(first.scannedThroughSeq, 10);
  assert.equal(first.throughSeq, 13);
  assert.equal(first.hasMore, true);
  assert.equal(first.truncated, true);
  lines.push(line(14, 'match'));
  const next = searchLogs('r', lines, true, new URLSearchParams({ q: 'match', after: '10', through: '13', context: '5' }));
  assert.equal(next.hasMore, false);
  assert.equal(next.scannedThroughSeq, 13);
  assert.deepEqual(next.matches.map(m => m.line.seq), [12]);
  assert.deepEqual(next.matches[0]!.before.map(l => l.seq), [10, 11]);
  assert.deepEqual(next.matches[0]!.after.map(l => l.seq), [13]);
  assert.equal(searchLogs('r', [], true, new URLSearchParams({ q: 'match' })).matches.length, 0);
  const evicted = searchLogs('r', [], true, new URLSearchParams({ q: 'match', after: '10', through: '13' }), 20);
  assert.equal(evicted.throughSeq, 13); assert.equal(evicted.scannedThroughSeq, 13); assert.equal(evicted.truncated, true);
});

test('search rejects malformed and unbounded queries', () => {
  const emoji = '😀'.repeat(200);
  assert.equal(searchLogs('r', [line(1, emoji)], false, new URLSearchParams({ q: emoji })).matches.length, 1);
  assert.throws(() => searchLogs('r', [], false, new URLSearchParams({ q: emoji + '😀' })), RangeError);
  for (const query of ['', 'q=', `q=${'x'.repeat(201)}`, 'q=x&limit=0', 'q=x&limit=101', 'q=x&after=-1', 'q=x&after=1.5', 'q=x&through=9007199254740992', 'q=x&context=6', 'q=x&caseSensitive=1']) {
    assert.throws(() => searchLogs('r', [], false, new URLSearchParams(query)), RangeError, query);
  }
});
