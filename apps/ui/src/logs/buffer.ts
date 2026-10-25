/**
 * Bounded, seq-ordered window over one run's log lines.
 *
 * - Live lines are appended (deduplicated by seq); beyond `cap` the oldest lines are dropped
 *   from memory (still on the daemon → `hasMoreBefore`, reloadable via `before=` pages).
 * - Older pages can be prepended; if that overflows `cap`, the newest lines are dropped and the
 *   window becomes `detached` from the live tail until newer pages are loaded again.
 */
import type { LogLine } from '@devpanel/contract';

export const DEFAULT_LOG_CAP = 50_000;

export class LogBuffer {
  readonly cap: number;
  lines: LogLine[] = [];
  /** Older lines exist on the daemon beyond `firstSeq`. */
  hasMoreBefore = false;
  /** Newer lines exist on the daemon beyond `lastSeq` (window is not at the live tail). */
  detached = false;
  /** Lines were dropped from memory because of `cap` (as opposed to daemon-side truncation). */
  localTrimmed = false;
  /** Total lines dropped from the front so far (for diagnostics). */
  droppedFront = 0;

  constructor(cap: number = DEFAULT_LOG_CAP) {
    this.cap = cap;
  }

  get size(): number {
    return this.lines.length;
  }
  get firstSeq(): number | null {
    return this.lines[0]?.seq ?? null;
  }
  get lastSeq(): number | null {
    return this.lines[this.lines.length - 1]?.seq ?? null;
  }

  reset(lines: readonly LogLine[] = [], hasMoreBefore = false): void {
    this.lines = normalize(lines);
    this.hasMoreBefore = hasMoreBefore;
    this.detached = false;
    this.localTrimmed = false;
    this.droppedFront = 0;
    this.trimFront();
  }

  /** Live append. Returns the number of lines added (0 while detached). */
  append(incoming: readonly LogLine[]): number {
    if (this.detached || incoming.length === 0) return 0;
    const last = this.lastSeq ?? 0;
    let from = 0;
    while (from < incoming.length && incoming[from]!.seq <= last) from++;
    if (from >= incoming.length) return 0;
    let added = 0;
    let prev = last;
    for (let i = from; i < incoming.length; i++) {
      const l = incoming[i]!;
      if (l.seq <= prev) continue; // tolerate out-of-order duplicates
      this.lines.push(l);
      prev = l.seq;
      added++;
    }
    this.trimFront();
    return added;
  }

  /** Insert an older page (lines with seq < firstSeq). Returns the number of lines added. */
  prepend(page: readonly LogLine[], hasMoreBefore: boolean): number {
    const first = this.firstSeq ?? Number.POSITIVE_INFINITY;
    const older = normalize(page).filter((l) => l.seq < first);
    this.hasMoreBefore = hasMoreBefore;
    if (older.length === 0) return 0;
    this.lines = older.concat(this.lines);
    if (this.lines.length > this.cap) {
      this.lines.length = this.cap; // drop newest
      this.detached = true;
    }
    return older.length;
  }

  /** While detached: append a newer page fetched with after=lastSeq. */
  appendPage(page: readonly LogLine[], hasMoreAfter: boolean): number {
    const wasDetached = this.detached;
    this.detached = false;
    const added = this.append(page);
    this.detached = wasDetached && hasMoreAfter;
    return added;
  }

  indexOfSeq(seq: number): number {
    let lo = 0;
    let hi = this.lines.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.lines[mid]!.seq < seq) lo = mid + 1;
      else hi = mid;
    }
    return lo < this.lines.length && this.lines[lo]!.seq === seq ? lo : -1;
  }

  private trimFront(): void {
    const over = this.lines.length - this.cap;
    if (over > 0) {
      this.lines.splice(0, over);
      this.hasMoreBefore = true;
      this.localTrimmed = true;
      this.droppedFront += over;
    }
  }
}

function normalize(lines: readonly LogLine[]): LogLine[] {
  const out: LogLine[] = [];
  let prev = -Infinity;
  let sorted = true;
  for (const l of lines) {
    if (l.seq <= prev) sorted = false;
    prev = l.seq;
  }
  const src = sorted ? lines : [...lines].sort((a, b) => a.seq - b.seq);
  prev = -Infinity;
  for (const l of src) {
    if (l.seq === prev) continue;
    out.push(l);
    prev = l.seq;
  }
  return out;
}
