import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, lstat, mkdir, readFile, realpath, unlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import type { DaemonInfo, Operation } from "@devpanel/contract";
import { api, ClientError, homePath, operationCode } from "./client.ts";
import { stableNodePath } from "./node-path.ts";

const exec = promisify(execFile);
const marker = "<!-- DevPanel LaunchAgent v1 -->";
const baseKeys = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "PATH"];
const systemPath = "/usr/bin:/bin:/usr/sbin:/sbin";
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const fault = (message: string) => new ClientError({ error: { code: "INTERNAL", message } });
const xml = (s: string) => {
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f]/u.test(s)) throw fault("LaunchAgent 配置含无效 XML 字符");
  return s.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&apos;");
};

// Explicit dependencies allow lifecycle tests without touching the user's launchd domain.
export interface LaunchAgentOptions {
  platform: string;
  userHome: string;
  home: string;
  uid: number;
  node: string;
  daemon: string;
  env: NodeJS.ProcessEnv;
  launchctl: (args: string[]) => Promise<string>;
  request: typeof api;
}
export function launchAgentOptions(): LaunchAgentOptions {
  return {
    platform: process.platform, userHome: homedir(), home: homePath(),
    uid: process.getuid?.() ?? -1, node: process.execPath,
    daemon: fileURLToPath(import.meta.resolve("@devpanel/daemon")), env: process.env,
    launchctl: async (args) => (await exec("/bin/launchctl", args, { timeout: 10000 })).stdout,
    request: api,
  };
}
async function canonicalPath(path: string): Promise<string> {
  try { return await realpath(path); }
  catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
    return join(await canonicalPath(dirname(path)), basename(path));
  }
}
async function context(o: LaunchAgentOptions) {
  if (o.platform !== "darwin" || o.uid < 0)
    throw new ClientError({ error: { code: "BAD_REQUEST", message: "daemon install/uninstall 仅支持 macOS 用户 LaunchAgent" } });
  // Resolve symlink aliases so one data directory always has one job label.
  const home = await canonicalPath(resolve(o.home));
  const label = "io.devpanel.daemon." + createHash("sha256").update(home).digest("hex").slice(0, 16);
  const domain = `gui/${o.uid}`;
  return { home, label, domain, target: `${domain}/${label}`, plistPath: join(o.userHome, "Library/LaunchAgents", label + ".plist") };
}
async function ownedFile(path: string) {
  try {
    const info = await lstat(path);
    if (!info.isFile()) throw fault("LaunchAgent 路径已被其他文件占用，未修改");
    const text = await readFile(path, "utf8");
    if (!text.includes(marker)) throw fault("LaunchAgent 文件不是 DevPanel 创建的，未修改");
    return text;
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw e;
  }
}
async function job(o: LaunchAgentOptions, target: string) {
  try { return await o.launchctl(["print", target]); }
  catch (e) {
    const error = e as { code?: number; stderr?: string };
    if (error.code === 113 && error.stderr?.includes("Could not find service")) return null;
    throw fault("无法查询 launchd job，未修改安装；请确认当前 GUI 用户会话及 launchctl 权限");
  }
}
async function daemonInfo(o: LaunchAgentOptions) {
  try { return await o.request<DaemonInfo>("/daemon"); }
  catch (e) {
    if (e instanceof ClientError && e.body.error.code === "DAEMON_UNREACHABLE") return null;
    throw e;
  }
}

export async function installLaunchAgent(o = launchAgentOptions()) {
  const c = await context(o);
  const existing = await ownedFile(c.plistPath);
  if (await job(o, c.target) !== null) {
    if (!existing) throw fault("同名 launchd job 已存在但缺少 DevPanel 安装文件，未修改");
    return { installed: true, alreadyInstalled: true, label: c.label, plistPath: c.plistPath };
  }
  if (await daemonInfo(o))
    throw fault("daemon 已由其他入口启动；请先 devpanel daemon stop（有服务时加 --stop-services），再安装 LaunchAgent");
  let base: Record<string, string>;
  try { base = JSON.parse(await readFile(join(c.home, "environment.json"), "utf8")); }
  catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw fault("无法读取 daemon 基础环境文件");
    base = Object.fromEntries(baseKeys.flatMap((key) => o.env[key] ? [[key, o.env[key]!]] : []));
  }
  if (!base || typeof base !== "object" || Array.isArray(base)) throw fault("daemon 基础环境文件格式无效");
  const environment: Record<string, string> = {};
  for (const key of baseKeys) {
    if (base[key] !== undefined && typeof base[key] !== "string") throw fault("daemon 基础环境文件格式无效");
    if (base[key]) environment[key] = base[key]!;
  }
  environment.PATH ||= systemPath;
  environment.DEVPANEL_HOME = c.home;
  const port = o.env.DEVPANEL_PORT ?? "47823";
  if (!/^\d+$/.test(port) || Number(port) > 65535)
    throw new ClientError({ error: { code: "BAD_REQUEST", message: "DEVPANEL_PORT 必须是 0–65535 的整数" } });
  environment.DEVPANEL_PORT = port;
  if (o.env.DEVPANEL_UI_DIR) environment.DEVPANEL_UI_DIR = resolve(o.env.DEVPANEL_UI_DIR);
  let node: string;
  try { node = stableNodePath(o.node); }
  catch (e) { throw fault((e as Error).message); }
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
${marker}
<plist version="1.0"><dict>
<key>Label</key><string>${xml(c.label)}</string>
<key>ProgramArguments</key><array><string>${xml(node)}</string><string>${xml(o.daemon)}</string></array>
<key>WorkingDirectory</key><string>${xml(c.home)}</string>
<key>EnvironmentVariables</key><dict>${Object.entries(environment).map(([key, value]) => `<key>${xml(key)}</key><string>${xml(value)}</string>`).join("")}</dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><false/>
<key>ProcessType</key><string>Background</string>
<key>AbandonProcessGroup</key><true/>
<key>StandardOutPath</key><string>/dev/null</string>
<key>StandardErrorPath</key><string>/dev/null</string>
</dict></plist>
`;
  await mkdir(c.home, { recursive: true, mode: 0o700 });
  await mkdir(join(o.userHome, "Library/LaunchAgents"), { recursive: true, mode: 0o700 });
  // An installed but unloaded job is reused without silently changing its environment.
  if (!existing) await writeFile(c.plistPath, plist, { mode: 0o600, flag: "wx" });
  await chmod(c.plistPath, 0o600);
  try {
    await o.launchctl(["bootstrap", c.domain, c.plistPath]);
  } catch {
    if (!existing && await job(o, c.target) === null) await unlink(c.plistPath);
    throw fault("launchctl bootstrap 失败；请在已登录的 macOS GUI 用户会话中安装，并检查是否有同名 job 或禁用设置");
  }
  for (let i = 0; i < 100; i++) {
    const info = await daemonInfo(o);
    if (info) {
      const loaded = await job(o, c.target);
      const pid = loaded?.match(/^\s*pid = (\d+)\s*$/m)?.[1];
      if (pid && info.pid === Number(pid))
        return { installed: true, alreadyInstalled: false, label: c.label, plistPath: c.plistPath };
    }
    await sleep(50);
  }
  throw fault("LaunchAgent 已安装，但 daemon 未就绪；请检查端口及源码/Node 路径，可先 uninstall 再手动 daemon start 排查");
}

export async function uninstallLaunchAgent(stopServices: boolean, o = launchAgentOptions()) {
  const c = await context(o);
  const existing = await ownedFile(c.plistPath);
  const loaded = await job(o, c.target);
  if (!existing) {
    if (loaded !== null) throw fault("同名 job 缺少 DevPanel 安装文件，未卸载");
    return { installed: false, label: c.label, plistPath: c.plistPath };
  }
  if (loaded !== null) {
    const pid = loaded.match(/^\s*pid = (\d+)\s*$/m)?.[1];
    if (pid) {
      const info = await daemonInfo(o);
      if (!info || info.pid !== Number(pid))
        throw fault("无法核验 LaunchAgent 对应的 daemon；未卸载，请确认管理服务可连接后重试");
      const result = await o.request<Operation | Record<string, never>>("/daemon/shutdown", "POST", { stopServices });
      if ("state" in result && operationCode(result as Operation) !== 0) return result;
      // Shutdown responds before closing the socket. Do not bootout until it finishes.
      for (let i = 0; i < 100; i++) {
        if (!(await daemonInfo(o))) break;
        if (i === 99) throw fault("daemon 尚未退出，LaunchAgent 保留，请稍后重试卸载");
        await sleep(50);
      }
    }
    try { await o.launchctl(["bootout", c.target]); }
    catch { throw fault("launchctl bootout 失败，保留安装文件，请稍后重试"); }
  }
  await unlink(c.plistPath);
  return { installed: false, label: c.label, plistPath: c.plistPath };
}
