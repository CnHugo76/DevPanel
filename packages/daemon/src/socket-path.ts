import { join } from "node:path";
import type { ApiError } from "@devpanel/contract";

/** sun_path includes the trailing NUL: macOS 104 bytes, Linux 108 bytes. */
export function socketPathError(
  home: string,
  platform: string = process.platform,
): ApiError | null {
  const capacity =
    platform === "darwin" ? 104 : platform === "linux" ? 108 : 104;
  const pathBytes = Buffer.byteLength(join(home, "run/devpanel.sock"), "utf8");
  const maxBytes = capacity - 1;
  if (pathBytes <= maxBytes) return null;
  const system =
    platform === "darwin"
      ? "macOS"
      : platform === "linux"
        ? "Linux"
        : "当前系统";
  return {
    code: "BAD_REQUEST",
    message: `DEVPANEL_HOME 过长：Unix socket 路径为 ${pathBytes} 字节；${system} 路径缓冲区限制 ${capacity} 字节（含结尾 NUL，路径最多 ${maxBytes} 字节）。请缩短 DEVPANEL_HOME；路径还需包含 /run/devpanel.sock。`,
    details: { pathBytes, maxBytes },
  };
}
