import type { LogDigest } from "@devpanel/contract";
export function digestText(d: LogDigest): string {
  const out = [
    `[digest ${d.runId} · 行 ${(d.lastSeq ?? 0) - d.scannedLines + 1}–${d.lastSeq ?? 0} · 错误块 ${d.errorBlocks}，省略 ${d.omitted.errorBlocks} · 省略 ${d.omitted.bytes} 字节]`,
  ];
  if (d.truncated) out.push("[较早的日志已被上限丢弃]");
  for (const b of d.blocks) {
    out.push(
      b.kind === "error"
        ? `── ERROR ×${b.occurrences} · 行 ${b.firstSeq}，最后 ${b.lastOccurrenceSeq} ──`
        : `── 末尾 ${b.lastSeq - b.firstSeq + 1} 行 ──`,
    );
    for (const l of b.lines) {
      out.push(
        `${l.seq} ${{ out: "O", err: "E", sys: "S" }[l.stream]} ${l.text}${(l.repeat ?? 1) >= 2 ? `  ×${l.repeat}` : ""}`,
      );
      if (l.folded) out.push(`      … 省略 ${l.folded.lines} 行堆栈`);
    }
  }
  return out.join("\n");
}
