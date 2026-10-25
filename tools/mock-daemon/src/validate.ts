import { readyIssues } from "./ready.ts";
import { existsSync, statSync, realpathSync } from 'node:fs';
import path from 'node:path';
import type {
  EnvMap,
  ProjectConfig,
  ServiceConfig,
  ServiceResolution,
  ValidateResult,
  ValidationIssue,
} from '@devpanel/contract';
import { refsIn, resolvableConfig, validateParams } from './params.ts';

/** PATH the mock daemon uses as its base environment (contract §3: decided by daemon config, not the caller's terminal). */
export const BASE_PATH = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin';

/**
 * A tiny virtual file system so the seeded projects (whose roots do not exist on this machine)
 * validate the same way a real daemon would. Real paths on disk are also honoured.
 */
const virtualDirs = new Set<string>();
const virtualFiles = new Set<string>();
const virtualBins: Record<string, string[]> = {
  '/opt/homebrew/bin': ['mvn', 'java', 'node', 'npm', 'npx', 'pnpm', 'yarn', 'uv', 'uvicorn', 'python3', 'go', 'docker', 'gradle'],
  '/usr/local/bin': ['docker'],
  '/usr/bin': ['python3', 'java', 'make', 'git', 'env', 'ruby', 'tail', 'true'],
  '/bin': ['zsh', 'bash', 'sh', 'sleep', 'ls', 'cat', 'echo'],
};

export function addVirtualDir(p: string): void {
  let cur = path.resolve(p);
  while (cur !== path.dirname(cur)) {
    virtualDirs.add(cur);
    cur = path.dirname(cur);
  }
}
export function addVirtualFile(p: string): void {
  virtualFiles.add(path.resolve(p));
  addVirtualDir(path.dirname(p));
}

export function isDir(p: string): boolean {
  const abs = path.resolve(p);
  if (virtualDirs.has(abs)) return true;
  try {
    return statSync(abs).isDirectory();
  } catch {
    return false;
  }
}
function isFile(p: string): boolean {
  const abs = path.resolve(p);
  if (virtualFiles.has(abs)) return true;
  try {
    return statSync(abs).isFile();
  } catch {
    return false;
  }
}

export function normalizeRoot(root: string): string {
  const abs = path.resolve(root);
  if (virtualDirs.has(abs)) return abs;
  try {
    return realpathSync(abs);
  } catch {
    return abs;
  }
}

function envPlain(env: EnvMap | undefined, key: string): string | undefined {
  const v = env?.[key];
  if (v === undefined) return undefined;
  if (typeof v === 'string') return v;
  return v.value;
}

export function effectivePath(cfg: ProjectConfig, svc: ServiceConfig): string {
  return envPlain(svc.env, 'PATH') ?? envPlain(cfg.env, 'PATH') ?? BASE_PATH;
}

export function resolveProgram(program: string, cwdAbs: string, pathUsed: string): string | null {
  if (!program) return null;
  if (program.includes('/')) {
    const abs = path.resolve(cwdAbs, program);
    return isFile(abs) ? abs : null;
  }
  for (const dir of pathUsed.split(':')) {
    if (!dir) continue;
    if (virtualBins[dir]?.includes(program)) return path.join(dir, program);
  }
  for (const dir of pathUsed.split(':')) {
    if (!dir || !path.isAbsolute(dir)) continue;
    const candidate = path.join(dir, program);
    if (existsSync(candidate) && isFile(candidate)) return candidate;
  }
  return null;
}

export function resolveService(cfg: ProjectConfig, svc: ServiceConfig): ServiceResolution {
  const root = typeof cfg.root === 'string' ? cfg.root : '';
  const cwd = typeof svc.cwd === 'string' && svc.cwd ? svc.cwd : '.';
  const cwdAbs = path.resolve(root || '/', cwd);
  const pathUsed = effectivePath(cfg, svc);
  const program = Array.isArray(svc.command) && typeof svc.command[0] === 'string' ? svc.command[0] : '';
  const cwdExists = isDir(cwdAbs);
  return {
    serviceId: svc.id,
    cwdAbs,
    cwdExists,
    program,
    programResolved: cwdExists || !program.includes('/') ? resolveProgram(program, cwdAbs, pathUsed) : null,
    pathUsed,
  };
}

const SERVICE_ID_RE = /^[a-z][a-z0-9-]{0,31}$/;
const SECRET_NAME_RE = /TOKEN|SECRET|PASSWORD|PASSWD|KEY|CREDENTIAL/i;
const SHELLS = new Set(['/bin/zsh', '/bin/bash', '/bin/sh', 'zsh', 'bash', 'sh']);

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function checkEnv(
  env: unknown,
  at: string,
  issues: ValidationIssue[],
  existingSecretKeys: Set<string> | null,
  secretParams: Set<string> = new Set(),
): void {
  if (env === undefined) return;
  if (!isObj(env)) {
    issues.push({ path: at, severity: 'error', code: 'CONFIG_INVALID', message: '环境变量必须是对象' });
    return;
  }
  for (const [k, v] of Object.entries(env)) {
    const p = `${at}.${k}`;
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) {
      issues.push({ path: p, severity: 'error', code: 'CONFIG_INVALID', message: `环境变量名不合法：${k}` });
    }
    if (typeof v === 'string') {
      // A value that only pulls in secret params (e.g. "${hfToken}") is not stored in plain text.
      const refs = refsIn(v);
      const fromSecretParams = refs.length > 0 && refs.every((r) => secretParams.has(r));
      if (SECRET_NAME_RE.test(k) && v && !fromSecretParams) {
        issues.push({
          path: p,
          severity: 'warning',
          code: 'WARN_SECRET_LIKE_PLAIN',
          message: `${k} 看起来是敏感值，但以明文保存`,
        });
      }
      continue;
    }
    if (isObj(v) && v.secret === true) {
      if (v.value === undefined) {
        // "keep" marker. In /config/validate (no project context) it is accepted;
        // in register/update the caller passes the set of keys that already have a stored value.
        if (existingSecretKeys && !existingSecretKeys.has(p)) {
          issues.push({ path: p, severity: 'error', code: 'CONFIG_INVALID', message: `${k} 没有已保存的值，不能“保持不变”` });
        }
      } else if (typeof v.value !== 'string') {
        issues.push({ path: p, severity: 'error', code: 'CONFIG_INVALID', message: `${k} 的值必须是字符串` });
      }
      continue;
    }
    issues.push({ path: p, severity: 'error', code: 'CONFIG_INVALID', message: `${k} 的值必须是字符串或 {secret:true}` });
  }
}

function backgroundHint(command: string[]): string | null {
  const shellText = command.length === 3 && SHELLS.has(command[0]!) && /^-l?c$/.test(command[1]!) ? command[2]! : null;
  if (shellText !== null) {
    if (/(^|[^&])&(\s*$|\s+[^&])/.test(shellText) || /&\s*$/.test(shellText)) return '“&”';
    if (/\bnohup\b/.test(shellText)) return '“nohup”';
    if (/\bdocker(-compose|\s+compose)?\b[^|;&]*\s(-d|--detach)\b/.test(shellText)) return '“-d”';
    if (/\bdisown\b|\bsetsid\b/.test(shellText)) return '后台化命令';
    return null;
  }
  if (command.includes('&') || command.some((a) => a.endsWith('&') && !a.endsWith('&&'))) return '“&”';
  if (command[0] === 'nohup' || command.includes('nohup')) return '“nohup”';
  if ((command[0] === 'docker' || command[0] === 'docker-compose') && (command.includes('-d') || command.includes('--detach')))
    return '“-d”';
  return null;
}

export interface ValidateOptions {
  /** Paths ("env.X", "services[i].env.X" keyed by service id: "svc:<id>.X") that have a stored secret. */
  existingSecrets?: Set<string> | null;
  /** v1.1-A. Param keys that have a stored secret value (register/update); omitted/null = standalone. */
  existingSecretParams?: Set<string> | null;
}

/** Explicit targets validate against the mock filesystem; no discovery or commands. */
function explicitTargetIssues(input: Record<string, unknown>): ValidationIssue[] {
  const issues: ValidationIssue[] = [];
  const fail = (path: string, message: string) => issues.push({ path, message, severity: 'error', code: 'CONFIG_INVALID' });
  for (const key of ['repositories', 'mavenProjects']) {
    const list = input[key];
    if (list === undefined) continue;
    if (!Array.isArray(list) || list.length > 32) { fail(key, '目标必须为数组，最多 32 项'); continue; }
    const ids = new Set<string>(), dirs = new Set<string>();
    list.forEach((value, i) => {
      const field = `${key}[${i}]`;
      if (!isObj(value)) { fail(field, '目标必须为对象'); return; }
      if (Object.keys(value).some(k => !['id', 'name', 'path', ...(key === 'mavenProjects' ? ['executable'] : [])].includes(k))) fail(field, '目标含未知字段');
      if (typeof value.id !== 'string' || !/^[a-z][a-z0-9-]{0,31}$/.test(value.id) || ids.has(value.id)) fail(field + '.id', '目标 ID 无效或重复');
      else ids.add(value.id);
      if (typeof value.name !== 'string' || !value.name.trim() || value.name.length > 80 || value.name.includes('\0')) fail(field + '.name', '请输入 1–80 字符名称');
      if (key === 'mavenProjects' && value.executable !== undefined && !['auto', 'wrapper', 'mvn'].includes(String(value.executable))) fail(field + '.executable', '可执行文件选择无效');
      if (typeof input.root !== 'string' || typeof value.path !== 'string' || !value.path || path.isAbsolute(value.path) || value.path.includes('\0') || value.path.includes('${') || value.path.split('/').includes('..')) { fail(field + '.path', '目标须为项目内相对目录'); return; }
      const root = normalizeRoot(input.root), dir = normalizeRoot(path.resolve(root, value.path));
      const rel = path.relative(root, dir);
      if (rel === '..' || rel.startsWith('../') || path.isAbsolute(rel) || !isDir(dir) || dirs.has(dir)) fail(field + '.path', '目标目录不可用、越界或重复');
      dirs.add(dir);
      const marker = path.join(dir, key === 'repositories' ? '.git' : 'pom.xml');
      if (key === 'repositories' ? !isDir(marker) && !isFile(marker) : !isFile(marker)) fail(field + '.path', '目标缺少 .git 或 pom.xml');
      if (key === 'mavenProjects') {
        const pomRel = path.relative(root, normalizeRoot(marker));
        if (pomRel.startsWith('../') || path.isAbsolute(pomRel)) fail(field + '.path', 'POM 越界');
      }
    });
  }
  return issues;
}

/** Same checks as POST /config/validate. Never executes anything. */
export function validateConfig(input: unknown, opts: ValidateOptions = {}): ValidateResult {
  const issues: ValidationIssue[] = [];
  const services: ServiceResolution[] = [];
  const existing = opts.existingSecrets ?? null;
  if (!isObj(input)) {
    return {
      ok: false,
      issues: [{ path: '', severity: 'error', code: 'CONFIG_INVALID', message: '配置必须是 JSON 对象' }],
      services,
    };
  }
  issues.push(...explicitTargetIssues(input));
  const cfg = input as unknown as ProjectConfig;
  if (Array.isArray(cfg.services)) cfg.services.forEach((s,i) => { if (s?.ready !== undefined) issues.push(...readyIssues(s.ready, cfg, `services[${i}].ready`)); });
  if (input.schemaVersion !== 1) {
    issues.push({ path: 'schemaVersion', severity: 'error', code: 'CONFIG_INVALID', message: 'schemaVersion 必须为 1' });
  }
  const instance = input.instance;
  if (instance !== undefined && (!isObj(instance) || !['group', 'name'].every(key => typeof instance[key] === 'string' && instance[key].trim().length > 0 && [...instance[key]].length >= 1 && [...instance[key]].length <= 80 && !/[\p{Cc}\p{Zl}\p{Zp}]/u.test(instance[key])))) issues.push({ path: 'instance', severity: 'error', code: 'CONFIG_INVALID', message: '实例分组和名称须为 1–80 字符单行文本' });
  if (typeof input.name !== 'string' || !input.name.trim()) {
    issues.push({ path: 'name', severity: 'error', code: 'CONFIG_INVALID', message: '项目名称不能为空' });
  }
  if (typeof input.root !== 'string' || !input.root) {
    issues.push({ path: 'root', severity: 'error', code: 'CONFIG_INVALID', message: '根目录不能为空' });
  } else if (!path.isAbsolute(input.root)) {
    issues.push({ path: 'root', severity: 'error', code: 'CONFIG_INVALID', message: '根目录必须是绝对路径' });
  } else if (!isDir(input.root)) {
    issues.push({ path: 'root', severity: 'error', code: 'CWD_UNAVAILABLE', message: `目录不存在：${input.root}` });
  }
  if (input.maven !== undefined && (!isObj(input.maven) || (input.maven.executable !== undefined && !['auto', 'wrapper', 'mvn'].includes(String(input.maven.executable))))) {
    issues.push({ path: 'maven.executable', severity: 'error', code: 'CONFIG_INVALID', message: 'Maven 可执行文件必须为 auto、wrapper 或 mvn' });
  }
  const secretParams = new Set(
    Array.isArray(input.params)
      ? input.params.flatMap((p: unknown) => (isObj(p) && p.secret === true && typeof p.key === 'string' ? [p.key] : []))
      : [],
  );
  checkEnv(input.env, 'env', issues, existing ? new Set([...existing].filter((k) => k.startsWith('env.'))) : null, secretParams);

  if (!Array.isArray(input.services) || input.services.length === 0) {
    issues.push({ path: 'services', severity: 'error', code: 'CONFIG_INVALID', message: '至少需要一个服务' });
    return { ok: !issues.some((i) => i.severity === 'error'), issues, services };
  }
  validateParams(input, issues, opts.existingSecretParams ?? (existing ? new Set() : null));
  // Program / PATH resolution uses the command after substituting non-secret param values.
  const { cfg: resolvable, blocked } = resolvableConfig(cfg);
  const seen = new Map<string, number>();
  input.services.forEach((raw: unknown, i: number) => {
    const at = `services[${i}]`;
    if (!isObj(raw)) {
      issues.push({ path: at, severity: 'error', code: 'CONFIG_INVALID', message: '服务必须是对象' });
      return;
    }
    const svc = raw as unknown as ServiceConfig;
    if (typeof raw.id !== 'string' || !SERVICE_ID_RE.test(raw.id)) {
      issues.push({
        path: `${at}.id`,
        severity: 'error',
        code: 'CONFIG_INVALID',
        message: 'ID 须为小写字母开头，只含小写字母、数字和连字符，最长 32 位',
      });
    } else if (seen.has(raw.id)) {
      issues.push({ path: `${at}.id`, severity: 'error', code: 'CONFIG_INVALID', message: `服务 ID 重复：${raw.id}` });
    } else {
      seen.set(raw.id, i);
    }
    if (typeof raw.name !== 'string' || !raw.name.trim()) {
      issues.push({ path: `${at}.name`, severity: 'error', code: 'CONFIG_INVALID', message: '服务名称不能为空' });
    }
    if (typeof raw.cwd !== 'string') {
      issues.push({ path: `${at}.cwd`, severity: 'error', code: 'CONFIG_INVALID', message: '工作目录必须是字符串' });
    }
    if (raw.stopTimeoutSec !== undefined) {
      const t = raw.stopTimeoutSec;
      if (typeof t !== 'number' || !Number.isInteger(t) || t < 1 || t > 300) {
        issues.push({ path: `${at}.stopTimeoutSec`, severity: 'error', code: 'CONFIG_INVALID', message: '停止等待须为 1–300 的整数秒' });
      }
    }
    const svcSecrets = existing
      ? new Set(
          [...existing]
            .filter((k) => k.startsWith(`svc:${String(raw.id)}.`))
            .map((k) => `${at}.env.${k.slice(`svc:${String(raw.id)}.`.length)}`),
        )
      : null;
    checkEnv(raw.env, `${at}.env`, issues, svcSecrets, secretParams);

    const cmdOk =
      Array.isArray(raw.command) && raw.command.length > 0 && raw.command.every((a: unknown) => typeof a === 'string');
    if (!cmdOk) {
      issues.push({ path: `${at}.command`, severity: 'error', code: 'CONFIG_INVALID', message: '启动命令不能为空（argv 数组）' });
    } else if (!(raw.command as string[])[0]) {
      issues.push({ path: `${at}.command[0]`, severity: 'error', code: 'CONFIG_INVALID', message: '程序名不能为空' });
    }
    if (!cmdOk || typeof raw.cwd !== 'string') return;

    const res = resolveService(resolvable, resolvable.services[i] ?? svc);
    services.push(res);
    if (!res.cwdExists) {
      issues.push({ path: `${at}.cwd`, severity: 'error', code: 'CWD_UNAVAILABLE', message: `工作目录不存在：${res.cwdAbs}` });
    } else if (!res.programResolved && !blocked.has(String(raw.id))) {
      const where = res.program.includes('/') ? `找不到文件 ${res.program}` : `在 PATH 中找不到 ${res.program}`;
      issues.push({ path: `${at}.command[0]`, severity: 'error', code: 'COMMAND_NOT_FOUND', message: where });
    }
    const bg = backgroundHint(svc.command);
    if (bg) {
      issues.push({
        path: `${at}.command`,
        severity: 'warning',
        code: 'WARN_BACKGROUND_COMMAND',
        message: `检测到 ${bg}：请使用前台运行方式，后台化的进程无法被管理`,
      });
    }
    const c = svc.command;
    if (c.length === 3 && SHELLS.has(c[0]!) && /^-l?c$/.test(c[1]!) && /&&|\|\||;|\|/.test(c[2]!)) {
      issues.push({
        path: `${at}.command`,
        severity: 'warning',
        code: 'WARN_SHELL_COMPOUND',
        message: 'Shell 命令包含 &&、;、| 等组合，考虑拆分为多个服务',
      });
    }
  });
  if (input.actions !== undefined) {
    if (!Array.isArray(input.actions)) {
      issues.push({ path: 'actions', severity: 'error', code: 'CONFIG_INVALID', message: '快捷操作必须是数组' });
    } else if (input.actions.length) {
      const actionSecrets = existing ? new Set([...existing].map((k) => k.startsWith('action:') ? `svc:${k.slice(7)}` : k)) : null;
      const check = validateConfig({ ...input, actions: undefined, services: input.actions }, { ...opts, existingSecrets: actionSecrets });
      issues.push(...check.issues.filter((x) => x.path.startsWith('services[')).map((x) => ({ ...x, path: x.path.replace(/^services/, 'actions') })));
      input.actions.forEach((a: unknown, i: number) => {
        if (!isObj(a)) return;
        if (a.description !== undefined && typeof a.description !== 'string') issues.push({ path: `actions[${i}].description`, severity: 'error', code: 'CONFIG_INVALID', message: '说明必须是字符串' });
        if (a.confirmWhenServicesRunning !== undefined && typeof a.confirmWhenServicesRunning !== 'boolean') issues.push({ path: `actions[${i}].confirmWhenServicesRunning`, severity: 'error', code: 'CONFIG_INVALID', message: '确认选项必须是布尔值' });
        if (a.timeoutSec !== undefined && (typeof a.timeoutSec !== 'number' || !Number.isInteger(a.timeoutSec) || a.timeoutSec < 1 || a.timeoutSec > 86400)) issues.push({ path: `actions[${i}].timeoutSec`, severity: 'error', code: 'CONFIG_INVALID', message: '最长运行时间须为 1–86400 的整数秒' });
      });
    }
  }
  return { ok: !issues.some((i) => i.severity === 'error'), issues, services };
}
