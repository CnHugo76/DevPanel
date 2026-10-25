import { stripVTControlCharacters } from "node:util";
import type {
  DigestLine,
  LogDigest,
  LogDigestBlock,
  LogLine,
} from "@devpanel/contract";
import { Fault } from "./storage.ts";

export function errorTitle(text: string): boolean {
  return (
    /\b(ERROR|FATAL|SEVERE)\b/.test(text) ||
    /^\s*[A-Za-z_$][\w$.]*(Exception|Error)(: |$)/.test(text) ||
    /^(Traceback \(most recent call last\):|panic:)/.test(text)
  );
}
export function stackLine(text: string, python: boolean): boolean {
  return (
    /^\s+at /.test(text) ||
    /^\s*(Caused by|Suppressed): /.test(text) ||
    /^\s+\.\.\. \d+ (more|common frames omitted)/.test(text) ||
    /^\s+File "/.test(text) ||
    (python && /^\s+\S/.test(text))
  );
}
function clipped(text: string): string {
  if (Buffer.byteLength(text) <= 1024) return text;
  const bytes = Buffer.from(text);
  let end = 1021;
  while ((bytes[end]! & 0xc0) === 0x80) end--;
  return bytes.subarray(0, end).toString() + "…";
}
function clean(line: LogLine): DigestLine {
  return {
    seq: line.seq,
    stream: line.stream,
    text: clipped(stripVTControlCharacters(line.text)),
  };
}
/** Fold as we scan; a long stack requires constant working memory. */
function fold(
  lines: Iterable<LogLine>,
  cap: number,
): { lines: DigestLine[]; lost: number } {
  const result: DigestLine[] = [];
  let frames = 0,
    causeFrames = 0,
    python = false,
    inStack = false,
    bytes = 0,
    lost = 0;
  for (const raw of lines) {
    const text = stripVTControlCharacters(raw.text),
      line = clean(raw);
    if (inStack && python && !stackLine(text, true)) {
      inStack = false;
      python = false;
    } else if (errorTitle(text)) {
      frames = 0;
      causeFrames = 0;
      python = text.startsWith("Traceback (most recent call last):");
      inStack = true;
    } else if (inStack && stackLine(text, python)) {
      let keep = true;
      if (/^\s*(Caused by|Suppressed): /.test(text)) causeFrames = 2;
      else if (/^\s+at /.test(text)) {
        frames++;
        keep = frames <= 5 || causeFrames > 0;
        if (causeFrames > 0) causeFrames--;
      } else if (/^\s+\.\.\. \d+ (more|common frames omitted)/.test(text))
        keep = false;
      if (!keep) {
        const previous = result.at(-1);
        if (previous)
          previous.folded = {
            lines: (previous.folded?.lines ?? 0) + 1,
            lastSeq: raw.seq,
          };
        else lost += Buffer.byteLength(JSON.stringify(line));
        continue;
      }
    } else inStack = false;
    const previous = result.at(-1);
    if (
      previous &&
      !previous.folded &&
      previous.stream === line.stream &&
      previous.text === line.text
    ) {
      previous.repeat = (previous.repeat ?? 1) + 1;
      continue;
    }
    const size = Buffer.byteLength(JSON.stringify(line)) + 1;
    if (bytes + size <= cap) {
      result.push(line);
      bytes += size;
    } else lost += size;
  }
  return { lines: result, lost };
}
interface ErrorMeta {
  first: number;
  end: number;
  last: number;
  count: number;
}
export function digest(
  runId: string,
  source: readonly LogLine[],
  truncated: boolean,
  runEnded: boolean,
  params: URLSearchParams,
): LogDigest {
  const number = (key: string, fallback: number, min: number, max: number) => {
    const raw = params.get(key);
    if (raw === null) return fallback;
    const value = Number(raw);
    if (
      !/^\d+$/.test(raw) ||
      !Number.isSafeInteger(value) ||
      value < min ||
      value > max
    )
      throw new Fault("BAD_REQUEST", `${key} 超出范围`);
    return value;
  };
  const maxBytes = number("maxBytes", 8192, 1024, 65536),
    tail = number("tail", 20, 0, 200),
    after = number("afterSeq", 0, 0, Number.MAX_SAFE_INTEGER);
  // Only metadata is retained per distinct signature; no second copy of the log is materialized.
  const errors = new Map<string, ErrorMeta>();
  let scannedLines = 0,
    lastSeq: number | null = null,
    start = source.length;
  for (let i = 0; i < source.length; i++) {
    const line = source[i]!;
    if (line.seq <= after) continue;
    if (start === source.length) start = i;
    scannedLines++;
    lastSeq = line.seq;
    const title = stripVTControlCharacters(line.text);
    if (!errorTitle(title)) continue;
    const python = title.startsWith("Traceback (most recent call last):");
    let end = i + 1,
      signatureText = title;
    while (
      end < source.length &&
      stackLine(stripVTControlCharacters(source[end]!.text), python)
    )
      end++;
    if (
      python &&
      end < source.length &&
      /^\S/.test(stripVTControlCharacters(source[end]!.text))
    ) {
      signatureText = stripVTControlCharacters(source[end]!.text);
      end++;
    }
    const signature = signatureText.replace(/\d+/g, "#"),
      old = errors.get(signature);
    if (old) {
      old.count++;
      old.last = line.seq;
    } else errors.set(signature, { first: i, end, last: line.seq, count: 1 });
    scannedLines += end - i - 1;
    lastSeq = source[end - 1]!.seq;
    i = end - 1;
  }
  const metas = [...errors.values()];
  let used = 2;
  const blocks: LogDigestBlock[] = [],
    omitted = { errorBlocks: 0, bytes: 0 };
  function* range(from: number, to: number) {
    for (let i = from; i < to; i++) yield source[i]!;
  }
  const add = (
    kind: "error" | "tail",
    from: number,
    to: number,
    meta?: ErrorMeta,
  ) => {
    if (from >= to) return;
    const folded = fold(range(from, to), maxBytes);
    const block: LogDigestBlock = {
      kind,
      firstSeq: source[from]!.seq,
      lastSeq: source[to - 1]!.seq,
      occurrences: meta?.count ?? 1,
      lastOccurrenceSeq: meta?.last ?? source[from]!.seq,
      lines: folded.lines,
    };
    const fullSize = Buffer.byteLength(JSON.stringify(block));
    let size = fullSize;
    while (
      block.lines.length &&
      used + size + (blocks.length ? 1 : 0) > maxBytes
    ) {
      block.lines.pop();
      size = Buffer.byteLength(JSON.stringify(block));
    }
    omitted.bytes += folded.lost + fullSize - size;
    if (!block.lines.length) {
      omitted.bytes += size;
      if (kind === "error") omitted.errorBlocks++;
      return;
    }
    used += size + (blocks.length ? 1 : 0);
    blocks.push(block);
  };
  const first = metas[0],
    last = metas.reduce<ErrorMeta | undefined>(
      (latest, meta) => (!latest || meta.last > latest.last ? meta : latest),
      undefined,
    );
  if (first) add("error", first.first, first.end, first);
  if (last && last !== first) add("error", last.first, last.end, last);
  if (tail) add("tail", Math.max(start, source.length - tail), source.length);
  for (const meta of metas)
    if (meta !== first && meta !== last)
      add("error", meta.first, meta.end, meta);
  blocks.sort((a, b) =>
    a.kind === b.kind ? a.firstSeq - b.firstSeq : a.kind === "tail" ? 1 : -1,
  );
  return {
    runId,
    afterSeq: params.has("afterSeq") ? after : null,
    lastSeq,
    scannedLines,
    errorBlocks: errors.size,
    blocks,
    omitted,
    truncated,
    runEnded,
  };
}
