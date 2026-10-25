import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ProcessInfo, ResourceSample } from "@devpanel/contract";
import { now, unavailable } from "./storage.ts";
const exec = promisify(execFile);
export interface ProcessRow extends ProcessInfo {
  pgid: number;
  cpuMs: number | null;
  rss: number | null;
  footprint?: number | null;
}
export const identity = (p: ProcessInfo) => `${p.pid}:${p.startedAt}`;
function cpuTime(s: string) {
  const [days, rest] = s.includes("-") ? s.split("-") : ["0", s];
  const pieces = rest!.split(":").map(Number);
  let seconds = 0;
  for (const p of pieces) seconds = seconds * 60 + p;
  return (Number(days) * 86400 + seconds) * 1000;
}
export async function scanProcesses(): Promise<Map<number, ProcessRow>> {
  const { stdout } = await exec(
    "/bin/ps",
    ["-axo", "pid=,ppid=,pgid=,rss=,time=,lstart=,stat=,comm="],
    {
      env: { ...process.env, LC_ALL: "C", TZ: "UTC" },
      maxBuffer: 16 * 1024 ** 2,
      timeout: 5000,
    },
  );
  const rows = new Map<number, ProcessRow>();
  for (const line of stdout.split("\n")) {
    const m = line
      .trim()
      .match(
        /^(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+([\d:.-]+)\s+(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+\s+\d+)\s+(\S+)\s+(.*)$/,
      );
    if (!m || m[7]!.includes("Z")) continue;
    const started = Date.parse(m[6]! + " UTC");
    if (!Number.isFinite(started)) continue;
    const pid = Number(m[1]);
    rows.set(pid, {
      pid,
      ppid: Number(m[2]),
      pgid: Number(m[3]),
      rss: Number(m[4]) * 1024,
      cpuMs: cpuTime(m[5]!),
      startedAt: new Date(started).toISOString(),
      command: m[8]!.split("/").pop() || "?",
    });
  }
  if (!rows.has(process.pid)) throw new Error("无法解析进程身份信息");
  return rows;
}
/** Only a verified live root or descendant can establish new ownership. */
export function discover(
  known: ProcessInfo[],
  rootPid: number | null,
  rows: Map<number, ProcessRow>,
): ProcessRow[] {
  const owned = new Map<number, ProcessRow>();
  for (const p of known) {
    const current = rows.get(p.pid);
    if (current && current.startedAt === p.startedAt) owned.set(p.pid, current);
  }
  const root = rootPid === null ? undefined : owned.get(rootPid);
  let changed = true;
  while (changed) {
    changed = false;
    for (const p of rows.values())
      if (
        !owned.has(p.pid) &&
        (owned.has(p.ppid) ||
          (root && p.pgid === root.pid && p.startedAt >= root.startedAt))
      ) {
        owned.set(p.pid, p);
        changed = true;
      }
  }
  return [...owned.values()];
}
export function verifiedSignal(
  known: ProcessInfo[],
  rows: Map<number, ProcessRow>,
  signal: NodeJS.Signals,
) {
  // Signal individuals, not -pgid: a group signal cannot verify every recipient.
  for (const p of [...known].reverse()) {
    const current = rows.get(p.pid);
    if (!current || current.startedAt !== p.startedAt) continue;
    try {
      process.kill(p.pid, signal);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "ESRCH") throw e;
    }
  }
}
export function resourceSample(
  rows: ProcessRow[],
  previous: Map<string, { cpu: number; at: number }>,
  at: number,
): ResourceSample {
  if (!rows.length) return unavailable();
  let cpu = 0,
    complete = true;
  for (const row of rows) {
    const old = previous.get(identity(row));
    if (row.cpuMs === null || !old || at <= old.at || row.cpuMs < old.cpu) complete = false;
    else cpu += ((row.cpuMs - old.cpu) / (at - old.at)) * 100;
  }
  const readable = rows.filter(p => p.rss !== null);
  const allFootprints = rows.every(p => p.footprint != null);
  if (!readable.length) return { ...unavailable(), processCount: rows.length, footprintBytes: null };
  return {
    status: readable.length < rows.length ? "partial" : complete ? "ok" : "sampling",
    sampledAt: now(),
    cpuPercent: complete ? cpu : null,
    rssBytes: readable.reduce((n, p) => n + p.rss!, 0),
    footprintBytes: allFootprints ? rows.reduce((n, p) => n + p.footprint!, 0) : null,
    ...(readable.length < rows.length ? { note: "部分进程资源读取失败；RSS 为已读取部分，footprint 不完整故不可用" } : {}),
    processCount: rows.length,
  };
}
