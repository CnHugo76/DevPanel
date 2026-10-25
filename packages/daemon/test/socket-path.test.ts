import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { socketPathError } from "../src/socket-path.ts";
import { startServer } from "../src/server.ts";

// The filesystem is never consulted by this validation.
test("Unix socket path limit counts UTF-8 bytes and reserves the terminating NUL", () => {
  for (const [platform, capacity] of [
    ["darwin", 104],
    ["linux", 108],
  ] as const) {
    const suffixBytes = Buffer.byteLength("/run/devpanel.sock");
    const allowed = "/" + "a".repeat(capacity - 2 - suffixBytes);
    assert.equal(
      Buffer.byteLength(join(allowed, "run/devpanel.sock")),
      capacity - 1,
    );
    assert.equal(socketPathError(allowed, platform), null);
    const error = socketPathError(allowed + "a", platform)!;
    assert.equal(error.code, "BAD_REQUEST");
    assert.deepEqual(error.details, {
      pathBytes: capacity,
      maxBytes: capacity - 1,
    });
    const unicode = "/" + "长".repeat(30);
    assert.ok(unicode.length + suffixBytes < capacity);
    assert.ok(socketPathError(unicode, platform));
  }
});

test("direct daemon entry rejects long socket path before creating data or locks", async (t) => {
  const base = await mkdtemp(join(tmpdir(), "devpanel-socket-"));
  t.after(() => rm(base, { recursive: true, force: true }));
  const home = join(base, "长".repeat(40));
  await assert.rejects(startServer(home, 0), (e: any) => {
    assert.equal(e.error.code, "BAD_REQUEST");
    assert.match(e.message, /Unix socket.*字节/);
    return true;
  });
  await assert.rejects(access(home));
});
