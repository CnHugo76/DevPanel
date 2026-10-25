import type { LogLine } from '@devpanel/contract';
import { parseAnsi, type Segment } from '../lib/ansi';

const segCache = new WeakMap<LogLine, Segment[]>();
const plainCache = new WeakMap<LogLine, string>();
const lowerCache = new WeakMap<LogLine, string>();

export function segmentsOf(line: LogLine): Segment[] {
  let s = segCache.get(line);
  if (!s) {
    s = parseAnsi(line.text);
    segCache.set(line, s);
  }
  return s;
}

export function plainOf(line: LogLine): string {
  let p = plainCache.get(line);
  if (p === undefined) {
    p = segmentsOf(line)
      .map((s) => s.text)
      .join('');
    plainCache.set(line, p);
  }
  return p;
}

function lowerOf(line: LogLine): string {
  let p = lowerCache.get(line);
  if (p === undefined) {
    p = plainOf(line).toLowerCase();
    lowerCache.set(line, p);
  }
  return p;
}

export interface Match {
  seq: number;
  start: number;
  end: number;
}

export const MAX_MATCHES = 100_000;

/** Case-insensitive substring search over the loaded lines (plain text, ANSI removed). */
export function findMatches(lines: readonly LogLine[], query: string, max: number = MAX_MATCHES): Match[] {
  const q = query.toLowerCase();
  if (!q) return [];
  const out: Match[] = [];
  for (const line of lines) {
    const text = lowerOf(line);
    let i = text.indexOf(q);
    while (i !== -1) {
      out.push({ seq: line.seq, start: i, end: i + q.length });
      if (out.length >= max) return out;
      i = text.indexOf(q, i + q.length);
    }
  }
  return out;
}

/** Plain text of lines for copying. sys lines get their visible prefix. */
export function linesToText(lines: readonly LogLine[]): string {
  return lines.map((l) => (l.stream === 'sys' ? `devpanel › ${plainOf(l)}` : plainOf(l))).join('\n');
}
