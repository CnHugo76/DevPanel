#!/usr/bin/env node
import { chmod, lstat, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { stableNodePath } from "./node-path.ts";

import { precompileNativeSampler } from "@devpanel/daemon/native-build";

const marker = "# DevPanel user CLI shim v1";
const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";

export async function installCli(binDir: string, node = process.execPath) {
  node = stableNodePath(node);
  const directory = resolve(binDir);
  const entries = [
    ["devpanel", fileURLToPath(new URL(import.meta.url.endsWith(".ts") ? "./main.ts" : "./main.js", import.meta.url))],
    ["devpaneld", fileURLToPath(import.meta.resolve("@devpanel/daemon"))],
  ] as const;
  // Check both destinations before changing either; never follow a foreign symlink.
  for (const [name] of entries) {
    const path = join(directory, name);
    try {
      const info = await lstat(path);
      if (!info.isFile() || !(await readFile(path, "utf8")).startsWith(`#!/bin/sh\n${marker}\n`))
        throw new Error(`${path} 已存在且不是 DevPanel shim，未覆盖`);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
    }
  }
  await mkdir(directory, { recursive: true });
  for (const [name, entry] of entries) {
    const path = join(directory, name), temp = `${path}.${process.pid}.tmp`;
    await writeFile(temp, `#!/bin/sh\n${marker}\nexec ${quote(node)} ${quote(entry)} "$@"\n`, { mode: 0o755 });
    await chmod(temp, 0o755);
    await rename(temp, path);
  }
  precompileNativeSampler();
  return directory;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { "bin-dir": { type: "string" } } });
    const directory = await installCli(values["bin-dir"] ?? join(homedir(), ".local/bin"));
    process.stdout.write(`已安装 ${directory}/devpanel 和 devpaneld\n`);
    if (!(process.env.PATH ?? "").split(":").includes(directory))
      process.stdout.write(`请在调用方环境中设置 PATH（未修改 shell 或系统配置）：\nexport PATH=${quote(directory)}:"$PATH"\n`);
  } catch (e) {
    process.stderr.write(`安装失败：${e instanceof Error ? e.message : "无法写入 shim"}\n`);
    process.exitCode = 1;
  }
}
