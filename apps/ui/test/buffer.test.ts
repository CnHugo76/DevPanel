import { describe, expect, it } from 'vitest';
import type { LogLine } from '@devpanel/contract';
import { LogBuffer } from '../src/logs/buffer';
import { findMatches } from '../src/logs/text';

const line = (seq: number, text = `line ${seq}`): LogLine => ({ seq, ts: '2026-10-20T02:42:07.118Z', stream: 'out', text });
const range = (a: number, b: number) => Array.from({ length: b - a + 1 }, (_, i) => line(a + i));
const seqs = (b: LogBuffer) => b.lines.map((l) => l.seq);

describe('LogBuffer', () => {
  it('appends in order and dedupes by seq', () => {
    const b = new LogBuffer(100);
    b.reset(range(1, 5));
    expect(b.append(range(4, 8))).toBe(3);
    expect(seqs(b)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(b.append(range(1, 8))).toBe(0);
  });

  it('accepts seq jumps (daemon-side truncation / gaps) but never goes backwards', () => {
    const b = new LogBuffer(100);
    b.reset(range(1, 3));
    b.append([line(10), line(9), line(11)]);
    expect(seqs(b)).toEqual([1, 2, 3, 10, 11]);
  });

  it('caps memory by dropping the oldest lines', () => {
    const b = new LogBuffer(10);
    b.reset(range(1, 5));
    b.append(range(6, 25));
    expect(b.size).toBe(10);
    expect(b.firstSeq).toBe(16);
    expect(b.lastSeq).toBe(25);
    expect(b.hasMoreBefore).toBe(true);
    expect(b.localTrimmed).toBe(true);
  });

  it('reset normalises unsorted / duplicate input and applies the cap', () => {
    const b = new LogBuffer(3);
    b.reset([line(5), line(3), line(4), line(4), line(2)], false);
    expect(seqs(b)).toEqual([3, 4, 5]);
    expect(b.hasMoreBefore).toBe(true);
  });

  it('prepends older pages; overflow drops the newest and detaches from the live tail', () => {
    const b = new LogBuffer(10);
    b.reset(range(21, 28), true);
    expect(b.prepend(range(15, 22), true)).toBe(6);
    expect(seqs(b)).toEqual(range(15, 24).map((l) => l.seq));
    expect(b.detached).toBe(true);
    // while detached, live lines are ignored (they would leave a hole)
    expect(b.append([line(29)])).toBe(0);
    // newer pages re-attach once the daemon says there is nothing more after
    b.appendPage(range(25, 27), true);
    expect(b.detached).toBe(true);
    b.appendPage(range(28, 29), false);
    expect(b.detached).toBe(false);
    expect(b.lastSeq).toBe(29);
    expect(b.size).toBe(10);
  });

  it('indexOfSeq finds lines by binary search', () => {
    const b = new LogBuffer(100);
    b.reset([line(2), line(5), line(9)]);
    expect(b.indexOfSeq(5)).toBe(1);
    expect(b.indexOfSeq(4)).toBe(-1);
  });
});

describe('findMatches', () => {
  it('searches case-insensitively in text without ANSI codes', () => {
    const lines = [line(1, '\x1b[32mINFO\x1b[0m OrderController ok'), line(2, 'nothing'), line(3, 'orderController orderCONTROLLER')];
    const m = findMatches(lines, 'ordercontroller');
    expect(m).toEqual([
      { seq: 1, start: 5, end: 20 },
      { seq: 3, start: 0, end: 15 },
      { seq: 3, start: 16, end: 31 },
    ]);
    expect(findMatches(lines, '')).toEqual([]);
    expect(findMatches(lines, '32m')).toEqual([]);
  });
});
