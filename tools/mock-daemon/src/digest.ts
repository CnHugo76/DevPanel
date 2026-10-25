import { readFileSync } from "node:fs";
import type { LogDigest } from "@devpanel/contract";
import { badRequest } from "./errors.ts";

/** Fixed contract examples for UI development; never analyzes the real daemon's logs. */
export function sampleDigest(
  runId: string,
  runEnded: boolean,
  params: URLSearchParams,
): LogDigest {
  for (const [name, min, max] of [
    ["afterSeq", 0, Number.MAX_SAFE_INTEGER],
    ["maxBytes", 1024, 65536],
    ["tail", 0, 200],
  ] as const) {
    const raw = params.get(name);
    if (
      raw !== null &&
      (!/^\d+$/.test(raw) ||
        !Number.isSafeInteger(Number(raw)) ||
        Number(raw) < min ||
        Number(raw) > max)
    )
      throw badRequest(`${name} 超出范围`);
  }
  const name = params.has("afterSeq")
    ? "after-seq"
    : Number(params.get("maxBytes") ?? 8192) < 2048
      ? "omitted"
      : "repeated";
  const result: LogDigest = JSON.parse(
    readFileSync(
      new URL(`../../../test-fixtures/digest/${name}.json`, import.meta.url),
      "utf8",
    ),
  );
  return {
    ...result,
    runId,
    runEnded,
    afterSeq: params.has("afterSeq") ? Number(params.get("afterSeq")) : null,
  };
}
