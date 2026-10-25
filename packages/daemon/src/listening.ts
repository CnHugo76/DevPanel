import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { isIP } from "node:net";
import type { ListeningPort, ProcessInfo } from "@devpanel/contract";
import { scanProcesses, identity } from "./processes.ts";
const exec = promisify(execFile);

/** Parse lsof field output; never infer ownership from an address or port. */
export function parseListening(
  output: string,
  allowed: Set<number>,
): ListeningPort[] {
  const ports: ListeningPort[] = [];
  let pid = 0,
    family: ListeningPort["family"] | undefined,
    name = "",
    state = "";
  const flush = () => {
    if (!allowed.has(pid) || !family || state !== "LISTEN") return;
    const m = name.match(/^(.*):(\d+)$/);
    if (!m) return;
    let address = m[1]!.replace(/^\[|\]$/g, "");
    if (address === "*") address = family === "ipv4" ? "0.0.0.0" : "::";
    const port = Number(m[2]);
    if (!isIP(address) || port < 1 || port > 65535) return;
    const scope =
      address === "0.0.0.0" || address === "::"
        ? "all"
        : address === "::1" || /^127\./.test(address)
          ? "loopback"
          : "other";
    ports.push({ pid, address, port, family, scope });
  };
  for (const line of output.split("\n")) {
    const tag = line[0],
      value = line.slice(1);
    if (tag === "p" || tag === "f") {
      flush();
      family = undefined;
      name = "";
      state = "";
    }
    if (tag === "p") pid = Number(value);
    if (tag === "t" && (value === "IPv4" || value === "IPv6"))
      family = value === "IPv4" ? "ipv4" : "ipv6";
    if (tag === "n") name = value;
    if (tag === "T" && value.startsWith("ST=")) state = value.slice(3);
  }
  flush();
  return ports;
}
export function serviceListening(
  rows: ProcessInfo[],
  result: Map<number, ListeningPort[]> | null,
): ListeningPort[] | null {
  if (!result || !rows.length || rows.some((p) => !result.has(p.pid)))
    return null;
  const unique = new Map<string, ListeningPort>();
  for (const p of rows)
    for (const port of result.get(p.pid)!) {
      const key = `${port.address}:${port.port}`;
      if (!unique.has(key)) unique.set(key, port);
    }
  return [...unique.values()].sort(
    (a, b) => a.port - b.port || a.address.localeCompare(b.address),
  );
}
/** One bounded lsof invocation per stats cycle, for verified PIDs only; recheck identities after IO. */
export async function readListening(
  known: ProcessInfo[],
  scan: () => Promise<Map<number, ProcessInfo>> = scanProcesses,
): Promise<Map<number, ListeningPort[]> | null> {
  if (!known.length) return null;
  const pids = [...new Set(known.map((p) => p.pid))];
  let stdout = "";
  try {
    const result = await exec(
      process.platform === "darwin" ? "/usr/sbin/lsof" : "lsof",
      [
        "-nP",
        "-a",
        "-p",
        pids.join(","),
        "-iTCP",
        "-sTCP:LISTEN",
        "-F",
        "pftnT",
      ],
      {
        timeout: 1500,
        maxBuffer: 4 * 1024 ** 2,
        env: { ...process.env, LC_ALL: "C" },
      },
    );
    if (result.stderr.trim()) return null;
    stdout = result.stdout;
  } catch (error) {
    const e = error as {
      code?: number;
      stdout?: string;
      stderr?: string;
      killed?: boolean;
    };
    // lsof returns 1, with no diagnostic, when no selected sockets exist.
    if (e.code !== 1 || e.killed || e.stderr?.trim() || e.stdout?.trim())
      return null;
  }
  try {
    const after = await scan();
    const result = new Map<number, ListeningPort[]>();
    for (const p of known)
      if (after.has(p.pid) && identity(after.get(p.pid)!) === identity(p))
        result.set(p.pid, []);
    for (const port of parseListening(stdout, new Set(result.keys())))
      result.get(port.pid)!.push(port);
    return result;
  } catch {
    return null;
  }
}
