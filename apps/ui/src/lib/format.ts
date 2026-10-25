const KiB = 1024;
const MiB = KiB * 1024;
const GiB = MiB * 1024;

export function formatBytes(n: number): string {
  if (n < KiB) return `${n} B`;
  if (n < MiB) return `${(n / KiB).toFixed(1)} KiB`;
  if (n < GiB) {
    const v = n / MiB;
    return `${v >= 100 || Number.isInteger(v) ? Math.round(v) : v.toFixed(1)} MiB`;
  }
  return `${(n / GiB).toFixed(2)} GiB`;
}

/** 100% = one logical CPU fully used; never capped. */
export function formatCpu(p: number): string {
  return `${p.toFixed(1)}%`;
}

/** 1h12m · 3m05s · 45s · 2d3h */
export function formatDuration(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (d > 0) return `${d}d${h}h`;
  if (h > 0) return `${h}h${String(m).padStart(2, '0')}m`;
  if (m > 0) return `${m}m${String(sec).padStart(2, '0')}s`;
  return `${sec}s`;
}

const pad = (n: number) => String(n).padStart(2, '0');

export function formatClock(ts: string | number): string {
  const d = new Date(ts);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

export function formatClockMs(ts: string | number): string {
  const d = new Date(ts);
  return `${formatClock(ts)}.${String(d.getMilliseconds()).padStart(3, '0')}`;
}

function sameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

/** "10:42" today, "昨天 18:02", otherwise "10/18 18:02". */
export function formatDayTime(ts: string | number, now: number = Date.now()): string {
  const d = new Date(ts);
  const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const today = new Date(now);
  if (sameDay(d, today)) return hm;
  const y = new Date(now - 86400_000);
  if (sameDay(d, y)) return `昨天 ${hm}`;
  return `${d.getMonth() + 1}/${d.getDate()} ${hm}`;
}

/** "10:12–10:40", "昨天 18:02–19:30" (end shown without day when same day as start). */
export function formatRange(start: string, end: string | null, now: number = Date.now()): string {
  const s = formatDayTime(start, now);
  if (!end) return `${s} 起`;
  const e = new Date(end);
  const sameAsStart = sameDay(new Date(start), e);
  const hm = `${pad(e.getHours())}:${pad(e.getMinutes())}`;
  return `${s}–${sameAsStart ? hm : formatDayTime(end, now)}`;
}

export function formatAgo(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s} 秒前`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} 分钟前`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h} 小时前`;
  return `${Math.floor(h / 24)} 天前`;
}

export function formatCount(n: number): string {
  return n.toLocaleString('en-US');
}

/**
 * Short run label. ULID prefixes are timestamps (runs started close together share them),
 * so keep the random tail: keep the last 6 chars: r_01JC8ZB3P1XQ4K → r_P1XQ4K.
 */
export function shortRunId(id: string): string {
  const body = id.startsWith('r_') ? id.slice(2) : id;
  return body.length > 6 ? `r_${body.slice(-6)}` : id;
}

/** /Users/demo/Project/foo → ~/Project/foo */
export function tildePath(p: string): string {
  const m = /^(\/Users\/[^/]+|\/home\/[^/]+)(\/.*)?$/.exec(p);
  if (!m) return p;
  return `~${m[2] ?? ''}`;
}

/** Last two path segments: "~/Project/foo" → "Project/foo". */
export function pathTail(p: string): string {
  const t = tildePath(p);
  const parts = t.split('/').filter(Boolean);
  if (parts.length <= 3) return t;
  return `…/${parts.slice(-2).join('/')}`;
}
