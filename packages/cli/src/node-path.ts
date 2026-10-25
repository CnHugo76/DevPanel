import { accessSync, constants, statSync } from "node:fs";
import { join } from "node:path";

/** Keep Homebrew's opt symlink in installed launchers; never resolve it back into Cellar. */
export function stableNodePath(executable = process.execPath): string {
  const brew = executable.match(/^(.*)\/Cellar\/(node(?:@\d+(?:\.\d+)*)?)\/[^/]+\/bin\/node$/);
  if (!brew) return executable;
  const stable = join(brew[1]!, "opt", brew[2]!, "bin/node");
  try {
    accessSync(stable, constants.X_OK);
    if (!statSync(stable).isFile()) throw new Error("not a file");
  } catch {
    throw new Error(`找不到可执行的 Homebrew Node 稳定路径 ${stable}；请修复对应 formula 的 opt 链接后重新安装`);
  }
  return stable;
}
