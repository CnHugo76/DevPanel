import { stripVTControlCharacters } from 'node:util';
import type { LogLine, LogSearchPage } from '@devpanel/contract';

/** Iterates the retained buffer without copying it; only matched context is returned. */
export function searchLogs(runId: string, lines: readonly LogLine[], truncated: boolean, params: URLSearchParams, latestSeq = lines.at(-1)?.seq ?? 0): LogSearchPage {
  const q = params.get('q');
  if (q === null || [...q].length < 1 || [...q].length > 200) throw new RangeError('q 必须为 1–200 字符');
  const integer = (name: string, fallback: number, min: number, max = Number.MAX_SAFE_INTEGER) => {
    const raw = params.get(name);
    if (raw === null) return fallback;
    const n = Number(raw);
    if (!/^\d+$/.test(raw) || !Number.isSafeInteger(n) || n < min || n > max) throw new RangeError(`${name} 超出范围`);
    return n;
  };
  const sensitive = params.get('caseSensitive');
  if (sensitive !== null && sensitive !== 'true' && sensitive !== 'false') throw new RangeError('caseSensitive 必须为 true 或 false');
  const after = integer('after', 0, 0);
  const latest = latestSeq;
  const through = Math.min(integer('through', latest, 0), latest);
  const limit = integer('limit', 50, 1, 100);
  const context = integer('context', 2, 0, 5);
  const needle = sensitive === 'true' ? q : q.toLowerCase();
  const result: LogSearchPage = { runId, throughSeq: through, scannedThroughSeq: through, hasMore: false, truncated, matches: [] };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (line.seq <= after) continue;
    if (line.seq > through) break;
    const plain = stripVTControlCharacters(line.text);
    if (!(sensitive === 'true' ? plain : plain.toLowerCase()).includes(needle)) continue;
    const before: LogLine[] = [], following: LogLine[] = [];
    for (let j = Math.max(0, i - context); j < i; j++) before.push(lines[j]!);
    for (let j = i + 1; j < Math.min(lines.length, i + context + 1) && lines[j]!.seq <= through; j++) following.push(lines[j]!);
    result.matches.push({ line, before, after: following });
    if (result.matches.length === limit) {
      result.scannedThroughSeq = line.seq;
      result.hasMore = i + 1 < lines.length && lines[i + 1]!.seq <= through;
      break;
    }
  }
  return result;
}
