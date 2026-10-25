import { readFileSync, existsSync, rmSync } from "node:fs";
import { writeFile, rename, chmod } from "node:fs/promises";
import { join } from "node:path";
import { StringDecoder } from "node:string_decoder";
import type {
  Limits,
  LogInfo,
  LogLine,
  LogPage,
  LogStream,
} from "@devpanel/contract";
import { now, privateDir, Fault } from "./storage.ts";
import { digest } from "./digest.ts";
import { searchLogs } from "./log-search.ts";
import { redact } from "./config.ts";

interface BufferState {
  maxBytes: number;
  lines: LogLine[];
  sizes: number[];
  bytes: number;
  next: number;
  truncated: boolean;
  dirty: boolean;
  writing: boolean;
  reserved: number;
}
/** Memory and disk share a bounded retained tail; collection never awaits a consumer or disk write. */
export class Logs {
  states = new Map<string, BufferState>();
  openCollectors = new Map<string, number>();
  timer: NodeJS.Timeout;
  dir: string;
  onGlobalOverflow?: () => void;
  onLine?: (id: string, line: LogLine) => void;
  reserveSequence?: (id: string, exclusive: number) => void;
  limits: Limits;
  private onError: (id: string) => void;
  constructor(home: string, limits: Limits, onError: (id: string) => void) {
    this.limits = limits;
    this.onError = onError;
    this.dir = join(home, "logs");
    privateDir(this.dir);
    this.timer = setInterval(() => {
      void this.flush();
    }, 500);
    this.timer.unref();
  }
  create(id: string, sequenceFloor = 1, maxBytes = this.limits.logBytesPerRun) {
    if (this.states.has(id)) return;
    let lines: LogLine[] = [],
      truncated = false;
    const file = join(this.dir, `${id}.json`);
    if (existsSync(file)) {
      try {
        const data = JSON.parse(readFileSync(file, "utf8"));
        lines = data.lines;
        truncated = data.truncated;
      } catch {
        truncated = true;
      }
    }
    const sizes = lines.map((l) => Buffer.byteLength(JSON.stringify(l)) + 1);
    this.states.set(id, {
      maxBytes,
      lines,
      sizes,
      bytes: sizes.reduce((n, s) => n + s, 0),
      next: Math.max(sequenceFloor, (lines.at(-1)?.seq || 0) + 1),
      truncated,
      dirty: false,
      writing: false,
      reserved: sequenceFloor,
    });
  }
  add(id: string, stream: LogStream, text: string, partial = false) {
    const s = this.states.get(id);
    if (!s) return;
    if (Buffer.byteLength(text) > this.limits.logLineMaxBytes) {
      const bytes = Buffer.from(text);
      let start = 0;
      while (start < bytes.length) {
        let end = Math.min(bytes.length, start + this.limits.logLineMaxBytes);
        while (end < bytes.length && (bytes[end]! & 0xc0) === 0x80) end--;
        this.add(
          id,
          stream,
          bytes.subarray(start, end).toString("utf8"),
          end < bytes.length || partial,
        );
        start = end;
      }
      return;
    }
    if (s.next >= s.reserved) {
      const reserved = s.next + 4096;
      try {
        this.reserveSequence?.(id, reserved);
      } catch {
        this.onError(id);
        return;
      }
      s.reserved = reserved;
    }
    const line: LogLine = {
      seq: s.next++,
      ts: now(),
      stream,
      text,
      ...(partial ? { partial: true } : {}),
    };
    const bytes = Buffer.byteLength(JSON.stringify(line)) + 1;
    s.lines.push(line);
    this.onLine?.(id, line);
    s.sizes.push(bytes);
    s.bytes += bytes;
    s.dirty = true;
    this.trim(s, Math.max(0, s.maxBytes - 64));
    // Bound retained memory even when every run is current. Global eviction is FIFO by run creation.
    let excess =
      [...this.states.values()].reduce((n, x) => n + x.bytes, 0) -
      this.limits.logBytesGlobal;
    if (excess > 0) {
      this.onGlobalOverflow?.();
      excess =
        [...this.states.values()].reduce((n, x) => n + x.bytes, 0) -
        this.limits.logBytesGlobal;
    }
    if (excess > 0)
      for (const state of this.states.values()) {
        const before = state.bytes;
        this.trim(state, Math.max(0, before - excess));
        excess -= before - state.bytes;
        if (excess <= 0) break;
      }
  }
  private trim(s: BufferState, max: number) {
    let count = 0;
    while (s.bytes > max && count < s.sizes.length) {
      s.bytes -= s.sizes[count++]!;
      s.truncated = true;
      s.dirty = true;
    }
    if (count) {
      s.lines.splice(0, count);
      s.sizes.splice(0, count);
    }
  }
  /** Keep incomplete UTF-8 lines bounded, including a producer that never emits a newline. */
  collector(id: string, stream: "out" | "err", sensitive: string[]) {
    const decoder = new StringDecoder("utf8");
    let pending = "";
    let rawPending = "";
    let ended = false;
    // KMP prefix tables keep only a suffix that could become a secret on the next write.
    // A fixed max-secret-length tail delays a complete READY line forever on an idle pipe.
    const patterns = sensitive.filter(Boolean).map(secret => {
      const prefix = new Uint32Array(secret.length);
      for (let i = 1, matched = 0; i < secret.length; i++) {
        while (matched > 0 && secret[i] !== secret[matched]) matched = prefix[matched - 1]!;
        if (secret[i] === secret[matched]) matched++;
        prefix[i] = matched;
      }
      return { secret, prefix };
    });
    const overlap = (text: string) => {
      let longest = 0;
      for (const { secret, prefix } of patterns) {
        let matched = 0;
        for (let i = 0; i < text.length; i++) {
          const char = text[i]!;
          while (matched > 0 && char !== secret[matched]) matched = prefix[matched - 1]!;
          if (char === secret[matched]) matched++;
          if (matched === secret.length) matched = prefix[matched - 1]!;
        }
        longest = Math.max(longest, matched);
      }
      return longest;
    };
    this.openCollectors.set(id, (this.openCollectors.get(id) ?? 0) + 1);
    const consume = (flush = false) => {
      while (pending.length) {
        const newline = pending.indexOf("\n");
        if (
          newline >= 0 &&
          Buffer.byteLength(pending.slice(0, newline)) <=
            this.limits.logLineMaxBytes
        ) {
          this.add(id, stream, pending.slice(0, newline).replace(/\r$/, ""));
          pending = pending.slice(newline + 1);
        } else if (Buffer.byteLength(pending) > this.limits.logLineMaxBytes) {
          const bytes = Buffer.from(pending);
          let end = this.limits.logLineMaxBytes;
          while (end > 0 && (bytes[end]! & 0xc0) === 0x80) end--;
          this.add(id, stream, bytes.subarray(0, end).toString("utf8"), true);
          pending = bytes.subarray(end).toString("utf8");
        } else if (flush) {
          this.add(id, stream, pending);
          pending = "";
        } else break;
      }
    };
    // Redact before splitting lines. Hold an overlap so values split across
    // writes, newlines or maximum-sized log lines are never emitted in pieces.
    const feed = (text: string, flush: boolean) => {
      rawPending += text;
      let cut = flush
        ? rawPending.length
        : rawPending.length - overlap(rawPending);
      let previousCut = -1;
      while (!flush && previousCut !== cut) {
        previousCut = cut;
        for (const secret of sensitive) {
          const start = rawPending.indexOf(
            secret,
            Math.max(0, cut - secret.length + 1),
          );
          if (start >= 0 && start < cut && start + secret.length > cut)
            cut = start;
        }
      }
      pending += redact(rawPending.slice(0, cut), sensitive, 1);
      rawPending = rawPending.slice(cut);
      consume(flush);
    };
    return {
      write: (chunk: Buffer) => {
        if (!ended) feed(decoder.write(chunk), false);
      },
      end: () => {
        if (ended) return;
        ended = true;
        feed(decoder.end(), true);
        const remaining = (this.openCollectors.get(id) ?? 1) - 1;
        if (remaining > 0) this.openCollectors.set(id, remaining);
        else this.openCollectors.delete(id);
      },
    };
  }
  digest(id: string, params: URLSearchParams, ended: boolean) {
    const s = this.states.get(id);
    if (!s) throw new Fault("RUN_NOT_FOUND", "运行不存在", 404);
    return digest(id, s.lines, s.truncated, ended, params);
  }
  search(id: string, params: URLSearchParams) {
    const state = this.states.get(id);
    if (!state) throw new Fault('RUN_NOT_FOUND', '运行不存在', 404);
    try { return searchLogs(id, state.lines, state.truncated, params, state.next - 1); }
    catch (error) {
      if (error instanceof RangeError) throw new Fault('BAD_REQUEST', error.message);
      throw error;
    }
  }
  info(id: string): LogInfo {
    const s = this.states.get(id)!;
    return {
      firstSeq: s.lines[0]?.seq ?? null,
      lastSeq: s.lines.at(-1)?.seq ?? null,
      bytes: s.bytes,
      truncated: s.truncated,
    };
  }
  page(id: string, params: URLSearchParams, ended: boolean): LogPage {
    const s = this.states.get(id);
    if (!s) throw new Fault("RUN_NOT_FOUND", "运行不存在", 404);
    const integer = (name: string, fallback: number) => {
      const raw = params.get(name);
      if (raw === null) return fallback;
      const n = Number(raw);
      if (!Number.isSafeInteger(n) || n < 0)
        throw new Fault("BAD_REQUEST", `${name} 必须是非负整数`);
      return n;
    };
    const limit = Math.min(integer("limit", 500), this.limits.logPageMaxLines);
    if (limit < 1 || (params.has("before") && params.has("after")))
      throw new Fault("BAD_REQUEST", "分页参数无效");
    const before = integer("before", Number.MAX_SAFE_INTEGER),
      after = integer("after", 0);
    let lines = s.lines.filter((l) => l.seq < before && l.seq > after);
    lines = params.has("after") ? lines.slice(0, limit) : lines.slice(-limit);
    const first = lines[0]?.seq ?? after,
      last = lines.at(-1)?.seq ?? before;
    return {
      runId: id,
      lines,
      ...this.info(id),
      hasMoreBefore: s.lines.some((l) => l.seq < first),
      hasMoreAfter: s.lines.some((l) => l.seq > last),
      runEnded: ended,
    };
  }
  async flush() {
    await Promise.all(
      [...this.states].map(async ([id, s]) => {
        if (!s.dirty || s.writing) return;
        s.writing = true;
        s.dirty = false;
        const path = join(this.dir, `${id}.json`),
          temp = path + ".tmp";
        const data = JSON.stringify({ truncated: s.truncated, lines: s.lines });
        try {
          await writeFile(temp, data, { mode: 0o600 });
          await chmod(temp, 0o600);
          if (this.states.get(id) === s) await rename(temp, path);
          else await rmAsync(temp);
        } catch {
          s.dirty = true;
          this.onError(id);
        } finally {
          s.writing = false;
        }
      }),
    );
  }
  delete(id: string) {
    this.states.delete(id);
    this.openCollectors.delete(id);
    rmSync(join(this.dir, `${id}.json`), { force: true });
  }
  async close() {
    clearInterval(this.timer);
    while ([...this.states.values()].some((s) => s.writing))
      await new Promise((r) => setTimeout(r, 10));
    await this.flush();
  }
}
async function rmAsync(path: string) {
  try {
    const { unlink } = await import("node:fs/promises");
    await unlink(path);
  } catch {}
}
