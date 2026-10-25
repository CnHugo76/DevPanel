import { test } from "node:test";
import assert from "node:assert/strict";
import {
  parseListening,
  serviceListening,
  readListening,
} from "../src/listening.ts";
import { scanProcesses } from "../src/processes.ts";

test("socket parsing handles IPv4/IPv6 scopes, filters ownership/state and deduplicates per service", () => {
  const result = parseListening(
    "p10\nf1\ntIPv4\nn127.0.0.2:8000\nTST=LISTEN\nf2\ntIPv6\nn[::1]:8001\nTST=LISTEN\nf3\ntIPv6\nn*:8002\nTST=LISTEN\nf4\ntIPv4\nn*:8003\nTST=LISTEN\nf5\ntIPv4\nn192.168.1.5:8004\nTST=LISTEN\nf6\ntIPv4\nn127.0.0.2:8000\nTST=LISTEN\nf7\ntIPv4\nn127.0.0.1:9000\nTST=ESTABLISHED\np999\nf1\ntIPv4\nn*:9999\nTST=LISTEN\n",
    new Set([10]),
  );
  assert.deepEqual(
    result.map((p) => p.scope),
    ["loopback", "loopback", "all", "all", "other", "loopback"],
  );
  const row = { pid: 10, ppid: 1, startedAt: "", command: "node" };
  assert.equal(serviceListening([row], new Map([[10, result]]))!.length, 5);
  assert.deepEqual(serviceListening([row], new Map([[10, []]])), []);
  assert.equal(serviceListening([row], null), null);
  assert.equal(serviceListening([row], new Map()), null);
});

test("socket reader discards a PID whose post-read identity differs; idle does no work", async () => {
  assert.equal(await readListening([]), null);
  const self = (await scanProcesses()).get(process.pid)!;
  const result = await readListening([
    { ...self, startedAt: "1900-01-01T00:00:00.000Z" },
  ]);
  assert.ok(result);
  assert.equal(result.has(self.pid), false);
});
