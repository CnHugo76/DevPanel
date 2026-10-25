import { randomBytes } from "node:crypto";
import {
  mkdirSync,
  chmodSync,
  writeFileSync,
  renameSync,
  readFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import type { ErrorCode, ApiError, Limits } from "@devpanel/contract";

export const VERSION = "0.4.1";
export const now = () => new Date().toISOString();
export const homePath = () =>
  process.env.DEVPANEL_HOME ||
  join(homedir(), "Library/Application Support/DevPanel");
export const sleep = (ms: number) =>
  new Promise<void>((r) => setTimeout(r, ms));
export const limits: Limits = {
  activityKeptPerProject: 500,
  taskRunsKept: 5,
  logBytesPerTaskRun: 16 * 1024 ** 2,
  logBytesPerRun: 32 * 1024 ** 2,
  runsKeptPerService: 3,
  logBytesGlobal: 1024 ** 3,
  logLineMaxBytes: 64 * 1024,
  logPageMaxLines: 2000,
  statsIntervalMs: 2000,
  startGraceMs: 1000,
  defaultStopTimeoutSec: 10,
};
export function privateDir(path: string) {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  chmodSync(path, 0o700);
}
export function atomicWrite(path: string, data: unknown) {
  privateDir(dirname(path));
  const temp = `${path}.${process.pid}.tmp`;
  writeFileSync(temp, JSON.stringify(data), { mode: 0o600 });
  chmodSync(temp, 0o600);
  renameSync(temp, path);
}
export function readJSON<T>(path: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return fallback;
    throw new Error(`无法读取数据文件：${path}`);
  }
}
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export function id(prefix: "p" | "r" | "op" | "a") {
  if (prefix === "p")
    return (
      "p_" +
      [...randomBytes(10)]
        .map((x) => "abcdefghijklmnopqrstuvwxyz234567"[x % 32])
        .join("")
    );
  let time = BigInt(Date.now()),
    tail = BigInt("0x" + randomBytes(10).toString("hex")),
    s = "";
  for (let i = 0; i < 16; i++) {
    s = alphabet[Number(tail % 32n)] + s;
    tail /= 32n;
  }
  for (let i = 0; i < 10; i++) {
    s = alphabet[Number(time % 32n)] + s;
    time /= 32n;
  }
  return `${prefix}_${s}`;
}
export class Fault extends Error {
  status: number;
  error: ApiError;
  constructor(
    code: ErrorCode,
    message: string,
    status = 400,
    details?: Record<string, unknown>,
  ) {
    super(message);
    this.status = status;
    this.error = { code, message, ...(details ? { details } : {}) };
  }
}
export const unavailable = () => ({
  status: "unavailable" as const,
  sampledAt: null,
  cpuPercent: null,
  rssBytes: null,
  processCount: null,
});
