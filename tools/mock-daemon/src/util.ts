import { randomBytes } from 'node:crypto';

const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const BASE32_LOWER = 'abcdefghijklmnopqrstuvwxyz234567';

let lastUlidTime = 0;
let lastUlidRandom: number[] = [];

/** Monotonic ULID (26 chars, Crockford base32). */
export function ulid(time = Date.now()): string {
  let rand: number[];
  if (time <= lastUlidTime && lastUlidRandom.length === 16) {
    time = lastUlidTime;
    rand = lastUlidRandom.slice();
    for (let i = 15; i >= 0; i--) {
      if (rand[i]! < 31) {
        rand[i]!++;
        break;
      }
      rand[i] = 0;
    }
  } else {
    const bytes = randomBytes(16);
    rand = Array.from(bytes, (b) => b % 32);
  }
  lastUlidTime = time;
  lastUlidRandom = rand;
  let ts = '';
  let n = time;
  for (let i = 0; i < 10; i++) {
    ts = CROCKFORD[n % 32]! + ts;
    n = Math.floor(n / 32);
  }
  return ts + rand.map((r) => CROCKFORD[r]).join('');
}

/** Non-monotonic ULID for a specific (historic) time. */
export function ulidAt(time: number): string {
  let ts = '';
  let n = time;
  for (let i = 0; i < 10; i++) {
    ts = CROCKFORD[n % 32]! + ts;
    n = Math.floor(n / 32);
  }
  return ts + Array.from(randomBytes(16), (b) => CROCKFORD[b % 32]).join('');
}

export const newRunId = (time?: number): string => 'r_' + (time === undefined ? ulid() : ulidAt(time));
export const newOperationId = (): string => 'op_' + ulid();
export function newProjectId(): string {
  return 'p_' + Array.from(randomBytes(10), (b) => BASE32_LOWER[b % 32]).join('');
}
export const newToken = (): string => randomBytes(32).toString('hex');

export const iso = (t: number = Date.now()): string => new Date(t).toISOString();

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export function rand(min: number, max: number): number {
  return min + Math.random() * (max - min);
}
export function randInt(min: number, max: number): number {
  return Math.floor(rand(min, max + 1));
}
export function pick<T>(items: readonly T[]): T {
  return items[Math.floor(Math.random() * items.length)]!;
}

/** Local time with offset, e.g. 2026-10-20T10:42:07.118+08:00 (Spring Boot style). */
export function localIsoWithOffset(t: number): string {
  const d = new Date(t);
  const pad = (n: number, w = 2) => String(n).padStart(w, '0');
  const off = -d.getTimezoneOffset();
  const sign = off >= 0 ? '+' : '-';
  const abs = Math.abs(off);
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}` +
    `${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`
  );
}

export function clockTime(t: number): string {
  const d = new Date(t);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

export function formatDuration(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) return `${h}h${String(m).padStart(2, '0')}m`;
  return `${m}m${String(sec).padStart(2, '0')}s`;
}

function isPlainObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** JSON with sorted keys and undefined fields dropped (for structural comparison). */
export function stableStringify(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(stableStringify).join(',')}]`;
  if (isPlainObj(v)) {
    return `{${Object.keys(v)
      .filter((k) => v[k] !== undefined)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${stableStringify(v[k])}`)
      .join(',')}}`;
  }
  return JSON.stringify(v);
}
