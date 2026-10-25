import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { mkdir, stat, rename, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

export const nativeSamplerPath = fileURLToPath(new URL("../native/build/process-sampler", import.meta.url));
const source = fileURLToPath(new URL("../native/process-sampler.c", import.meta.url));
let build: Promise<string> | undefined;

/** Build once on source checkouts; packaged builds reuse the existing binary. */
export function prepareNativeSampler(): Promise<string> {
  return build ??= (async () => {
    if (process.platform !== "darwin") throw new Error("macOS sampler unavailable");
    const [src, bin] = await Promise.all([stat(source), stat(nativeSamplerPath).catch(() => null)]);
    if (bin && bin.mtimeMs >= src.mtimeMs) return nativeSamplerPath;
    await mkdir(dirname(nativeSamplerPath), { recursive: true });
    const temp = `${nativeSamplerPath}.${process.pid}.tmp`;
    try {
      await promisify(execFile)("/usr/bin/xcrun", ["clang", "-O2", "-Wall", "-Wextra", "-Werror", source, "-o", temp], { timeout: 30_000 });
      await rename(temp, nativeSamplerPath);
    } finally {
      await rm(temp, { force: true });
    }
    return nativeSamplerPath;
  })().catch(error => { build = undefined; throw error; });
}

/** Best effort precompile; build/setup callers return without waiting for clang. */
export function precompileNativeSampler() {
  if (process.platform !== "darwin") return;
  const child = spawn(process.execPath, [fileURLToPath(import.meta.url)], {
    detached: true, stdio: "ignore",
  });
  child.on("error", () => {});
  child.unref();
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url) && process.platform === "darwin") {
  if (process.argv.includes("--background")) precompileNativeSampler();
  else await prepareNativeSampler().catch(() => { process.exitCode = 1; });
}
