import { isIP } from "node:net";
import type { ListeningPort, ProcessInfo } from "@devpanel/contract";
import { readListening } from "./listening.ts";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { prepareNativeSampler } from "./native-build.ts";
import { identity, scanProcesses, type ProcessRow } from "./processes.ts";

type Pending = { resolve: (data: unknown) => void; reject: (error: Error) => void; timer: NodeJS.Timeout };
const failure = () => new Error("进程采样器不可用");
type FailureReason = "timeout" | "exit" | "io" | "invalid-output" | "build";
const uint = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;

/** One request-driven helper per Manager, shared by discovery, resource and stop checks. */
export class ProcessScanner {
  private child: ChildProcessWithoutNullStreams | null = null;
  private pending: Pending | null = null;
  private buffer = "";
  private queue: Promise<unknown> = Promise.resolve();
  private prepared: Promise<void> | null = null;
  private path: string | null = null;
  private closed = false;
  private readonly disabled = process.platform !== "darwin" || process.env.DEVPANEL_PROCESS_BACKEND === "ps";

  private retryAt = 0;
  private failures = 0;
  private readonly log: (line: string) => void;
  private readonly logCounts = new Map<string, { at: number; count: number; suppressed: number }>();
  private readonly now: () => number;
  private readonly timeoutMs: number;
  private readonly build: () => Promise<string>;
  constructor(helperPath?: string, options: {
    now?: () => number; timeoutMs?: number; build?: () => Promise<string>; log?: (line: string) => void;
  } = {}) {
    this.now = options.now ?? Date.now;
    this.timeoutMs = options.timeoutMs ?? 2000;
    this.log = options.log ?? (line => { process.stderr.write(line + "\n"); });
    this.build = options.build ?? (helperPath ? async () => helperPath : prepareNativeSampler);
  }

  get intervalMs() { return 250; }
  get helperPid() { return this.child?.pid ?? null; }
  /** Transient misses are partial samples, not authorization to reuse old identities. */
  get recovering() { return !this.closed && !this.disabled && this.failures > 0 && this.failures < 3; }
  private get fallback() { return this.disabled || this.path === null || this.failures >= 3; }
  private get available() {
    return !this.disabled && !this.closed && this.path !== null && this.now() >= this.retryAt;
  }

  /** Explicit warmup may be awaited by tests; production callers never await compilation. */
  prepare(): Promise<void> {
    if (this.disabled || this.closed || this.path || this.now() < this.retryAt) return Promise.resolve();
    return this.prepared ??= this.build().then(path => {
      if (!this.closed) this.path = path;
    }).catch(() => {
      if (!this.closed) this.fail("build");
    }).finally(() => { this.prepared = null; });
  }

  private diagnostic(event: string, reason: string, details: Record<string, unknown> = {}) {
    const now = this.now(), key = `${event}:${reason}`;
    const record = this.logCounts.get(key) ?? { at: -Infinity, count: 0, suppressed: 0 };
    record.count++;
    this.logCounts.set(key, record);
    if (now - record.at < 30_000) { record.suppressed++; return; }
    const suppressed = record.suppressed;
    record.at = now;
    record.suppressed = 0;
    // Only fixed categories and numeric metadata: never helper output, paths or ambient errors.
    try { this.log(JSON.stringify({ time: new Date(now).toISOString(), component: "process-sampler",
      event, reason, count: record.count, consecutiveFailures: this.failures, suppressed, ...details })); } catch {}
  }

  private fail(reason: FailureReason, details: Record<string, unknown> = {}) {
    if (this.closed) return;
    this.failures++;
    const retryMs = Math.min(2000 * 2 ** Math.min(this.failures - 1, 4), 30_000);
    this.retryAt = this.now() + retryMs;
    this.diagnostic("failure", reason, { ...details, retryMs });
    if (this.failures === 3) this.diagnostic("unavailable", reason, { retryMs });
    this.disconnect();
  }

  private succeeded() {
    if (this.failures) this.diagnostic("recovered", "valid-response");
    this.failures = 0;
    this.retryAt = 0;
  }

  private disconnect() {
    if (this.pending) {
      clearTimeout(this.pending.timer);
      this.pending.reject(failure());
      this.pending = null;
    }
    const child = this.child;
    this.child = null;
    this.buffer = "";
    // EOF, not an unchecked PID signal. The helper exits when its owner disappears.
    child?.stdin.end();
    child?.stdout.destroy();
    child?.stderr.destroy();
    child?.unref();
  }

  private request<T>(command: string, parse: (data: unknown[][]) => T): Promise<T> {
    const run = this.queue.catch(() => {}).then(async () => {
      if (!this.available) throw failure();
      if (!this.child) {
        const child = spawn(this.path!, [], { stdio: ["pipe", "pipe", "pipe"] });
        this.child = child;
        child.stdout.setEncoding("utf8");
        child.stdout.on("data", (chunk: string) => {
          if (this.child !== child) return;
          this.buffer += chunk;
          if (this.buffer.length > 16 * 1024 ** 2) { this.fail("invalid-output"); return; }
          const end = this.buffer.indexOf("\n");
          if (end < 0) return;
          try {
            const data: unknown = JSON.parse(this.buffer.slice(0, end));
            if (!Array.isArray(data) || !this.pending || end !== this.buffer.length - 1) throw failure();
            this.buffer = "";
            const pending = this.pending;
            this.pending = null;
            clearTimeout(pending.timer);
            pending.resolve(data);
          } catch { this.fail("invalid-output"); }
        });
        const onError = () => { if (this.child === child) this.fail("io"); };
        child.on("error", onError);
        child.on("exit", (code, signal) => {
          if (this.child === child) this.fail("exit", { exitCode: code, signal });
        });
        child.stdin.on("error", onError);
        child.stdout.on("error", onError);
        child.stderr.on("error", onError);
        child.stderr.resume(); // Never forward native diagnostics/ambient data to clients.
      }
      const child = this.child;
      const data = await new Promise<unknown>((resolve, reject) => {
        this.pending = { resolve, reject, timer: setTimeout(() => this.fail("timeout", { timeoutMs: this.timeoutMs }), this.timeoutMs) };
        child.stdin.write(command + "\n");
      });
      if (this.closed || this.child !== child) throw failure();
      // Validate before releasing the queue; a syntactically valid but wrong reply is a failure.
      try {
        const result = parse(data as unknown[][]);
        this.succeeded();
        return result;
      } catch {
        this.fail("invalid-output");
        throw failure();
      }
    });
    this.queue = run;
    return run;
  }

  async scan(): Promise<Map<number, ProcessRow>> {
    if (this.closed) throw failure();
    void this.prepare();
    if (this.available) {
      try {
        return await this.request("S", data => {
          const rows = new Map<number, ProcessRow>();
          for (const row of data) {
            if (!Array.isArray(row) || row.length !== 5 || !row.slice(0, 4).every(uint) || typeof row[4] !== "string") throw failure();
            const [pid, ppid, pgid, start, command] = row as [number, number, number, number, string];
            rows.set(pid, { pid, ppid, pgid, startedAt: new Date(start * 1000).toISOString(), command, cpuMs: null, rss: null });
          }
          if (!rows.has(process.pid)) throw failure();
          return rows;
        });
      } catch {}
    }
    if (this.closed || !this.fallback) throw failure();
    return scanProcesses();
  }

  async resources(rows: ProcessRow[]): Promise<ProcessRow[]> {
    void this.prepare();
    if (!rows.length) return rows;
    const unknown = () => rows.map(p => ({ ...p, rss: null, cpuMs: null, footprint: null }));
    if (!this.available) return this.fallback ? rows : unknown();
    try {
      const unique = [...new Map(rows.map(p => [identity(p), p])).values()];
      return await this.request("R " + unique.map(p => `${p.pid}:${Date.parse(p.startedAt) / 1000}`).join(" "), data => {
        const values = new Map<string, { rss: number; cpuMs: number; footprint: number }>();
        for (const row of data) {
          if (!Array.isArray(row) || row.length !== 5 || ![row[0], row[1], row[2], row[4]].every(uint) || typeof row[3] !== "number" || !Number.isFinite(row[3]) || row[3] < 0) throw failure();
          const [pid, start, rss, cpuMs, footprint] = row as number[];
          values.set(`${pid}:${new Date(start! * 1000).toISOString()}`, { rss: rss!, cpuMs: cpuMs!, footprint: footprint! });
        }
        return rows.map(p => ({ ...p, rss: null, cpuMs: null, footprint: null, ...values.get(identity(p)) }));
      });
    } catch {
      // A failed measurement is unknown; never retain an older reading or use zero.
      return unknown();
    }
  }

  /** Only the owner and this helper: business descendants are deliberately excluded. */
  async toolResources(): Promise<ProcessRow[] | null> {
    void this.prepare();
    if (!this.available) return null;
    try {
      return await this.request("O", data => {
        const expected = new Set([process.pid, this.helperPid]);
        if (data.length !== 2) throw failure();
        const rows: ProcessRow[] = [];
        for (const row of data) {
          if (!Array.isArray(row) || row.length !== 5 || ![row[0], row[1], row[2], row[4]].every(uint) ||
              typeof row[3] !== "number" || !Number.isFinite(row[3]) || row[3] < 0 || !expected.delete(row[0] as number)) throw failure();
          const [pid, start, rss, cpuMs, footprint] = row as number[];
          rows.push({ pid: pid!, ppid: pid === process.pid ? 0 : process.pid, pgid: 0,
            startedAt: new Date(start! * 1000).toISOString(), command: pid === process.pid ? "devpaneld" : "process-sampler",
            rss: rss!, cpuMs: cpuMs!, footprint: footprint! });
        }
        return rows;
      });
    } catch { return null; }
  }

  async listening(known: ProcessInfo[]): Promise<Map<number, ListeningPort[]> | null> {
    if (!known.length) return null;
    void this.prepare();
    if (this.available) {
      try {
        const unique = new Map(known.map(p => [p.pid, p]));
        return await this.request("P " + [...unique.values()].map(p => `${p.pid}:${Date.parse(p.startedAt) / 1000}`).join(" "), data => {
          const result = new Map<number, ListeningPort[]>();
          for (const row of data) {
            if (!Array.isArray(row) || row.length !== 3 || !uint(row[0]) || !uint(row[1])) throw failure();
            const pid = row[0], expected = unique.get(pid);
            if (!expected || Date.parse(expected.startedAt) !== row[1] * 1000) throw failure();
            if (row[2] === null) continue;
            if (!Array.isArray(row[2])) throw failure();
            const ports: ListeningPort[] = [];
            for (const port of row[2]) {
              if (!Array.isArray(port) || port.length !== 3 || !["ipv4", "ipv6"].includes(port[0]) ||
                  typeof port[1] !== "string" || isIP(port[1]) !== (port[0] === "ipv4" ? 4 : 6) ||
                  !uint(port[2]) || port[2] < 1 || port[2] > 65535) throw failure();
              const [family, address, number] = port as [ListeningPort["family"], string, number];
              const scope = address === "0.0.0.0" || address === "::" ? "all" : address === "::1" || /^127\./.test(address) ? "loopback" : "other";
              ports.push({ pid, family, address, port: number, scope });
            }
            result.set(pid, ports);
          }
          return result;
        });
      } catch {}
    }
    if (!this.fallback) return null;
    return readListening(known, () => this.scan());
  }

  close() {
    this.closed = true;
    this.disconnect();
  }
}
