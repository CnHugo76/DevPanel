/**
 * Editable form model for ProjectConfig (docs/ui-design.md §6) and lossless conversion both ways.
 * Secrets: values typed in the form are never shown again; in the JSON tab they appear as
 * {"secret": true} and are carried over through `secretValues`.
 */
import type { EnvMap, ProjectConfig, ServiceConfig } from '@devpanel/contract';
import { SHELL_FLAG, SHELL_PROGRAM, joinArgv, shellText, splitArgv } from './argv';

export interface EnvRow {
  key: string;
  name: string;
  value: string;
  secret: boolean;
  /** A value is stored on the daemon (leave empty to keep it). */
  stored: boolean;
  /** The user toggled the lock manually (stop auto-detecting from the name). */
  secretTouched: boolean;
}

export interface DraftService {
  key: string;
  id: string;
  /** ID follows the name until the user edits it (new services only). */
  idAuto: boolean;
  /** ID of the saved service this card edits, null for new ones. */
  origId: string | null;
  name: string;
  cwd: string;
  commandText: string;
  viaShell: boolean;
  shell: string;
  shellFlag: string;
  env: EnvRow[];
  stopTimeoutSec: string;
  collapsed: boolean;
}

export interface Draft {
  name: string;
  root: string;
  env: EnvRow[];
  services: DraftService[];
}

let keySeq = 0;
export const newKey = (): string => `k${++keySeq}`;

export const SECRET_NAME = /TOKEN|SECRET|PASSWORD|PASSWD|KEY|CREDENTIAL/i;
export const SERVICE_ID_RE = /^[a-z][a-z0-9-]{0,31}$/;

const WORDS: Record<string, string> = {
  后端: 'backend',
  前端: 'frontend',
  接口: 'api',
  服务: 'service',
  文档: 'docs',
  管理: 'admin',
  网关: 'gateway',
  任务: 'worker',
  队列: 'queue',
  数据库: 'db',
  缓存: 'cache',
  网站: 'web',
  定时: 'cron',
};

/** Lower-case slug for a service ID, unique among `taken`. */
export function slugify(name: string, taken: readonly string[]): string {
  let s = name.trim();
  for (const [zh, en] of Object.entries(WORDS)) s = s.split(zh).join(` ${en} `);
  s = s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .replace(/^[0-9-]+/, '');
  if (!s) s = 'service';
  s = s.slice(0, 28).replace(/-+$/, '');
  let candidate = s;
  let n = 2;
  while (taken.includes(candidate)) candidate = `${s}-${n++}`;
  return candidate;
}

export function emptyEnvRow(): EnvRow {
  return { key: newKey(), name: '', value: '', secret: false, stored: false, secretTouched: false };
}

export function emptyService(taken: readonly string[]): DraftService {
  const name = '';
  return {
    key: newKey(),
    id: slugify('service', taken),
    idAuto: true,
    origId: null,
    name,
    cwd: '.',
    commandText: '',
    viaShell: false,
    shell: SHELL_PROGRAM,
    shellFlag: SHELL_FLAG,
    env: [],
    stopTimeoutSec: '',
    collapsed: false,
  };
}

export function emptyDraft(): Draft {
  return { name: '', root: '', env: [], services: [emptyService([])] };
}

const scopeKey = (scope: string, name: string) => `${scope}\u0000${name}`;

/** Secret values typed into the form, keyed by (service id or "" for project, env name). */
export function secretValuesOf(d: Draft): Map<string, string> {
  const m = new Map<string, string>();
  for (const r of d.env) if (r.secret && r.value) m.set(scopeKey('', r.name.trim()), r.value);
  for (const s of d.services) for (const r of s.env) if (r.secret && r.value) m.set(scopeKey(s.id, r.name.trim()), r.value);
  return m;
}

/** Keys of secrets that have a stored value on the daemon (from the masked saved config). */
export function storedSecretsOf(cfg: ProjectConfig | null): Set<string> {
  const set = new Set<string>();
  if (!cfg) return set;
  for (const [k, v] of Object.entries(cfg.env ?? {})) if (typeof v !== 'string') set.add(scopeKey('', k));
  for (const s of cfg.services) for (const [k, v] of Object.entries(s.env ?? {})) if (typeof v !== 'string') set.add(scopeKey(s.id, k));
  return set;
}

function envRows(env: EnvMap | undefined, scope: string, values: Map<string, string>, stored: Set<string>): EnvRow[] {
  return Object.entries(env ?? {}).map(([name, v]) => {
    if (typeof v === 'string') return { key: newKey(), name, value: v, secret: false, stored: false, secretTouched: true };
    const typed = v.value ?? values.get(scopeKey(scope, name)) ?? '';
    return { key: newKey(), name, value: typed, secret: true, stored: stored.has(scopeKey(scope, name)), secretTouched: true };
  });
}

export function draftFromConfig(
  cfg: ProjectConfig,
  opts: { secretValues?: Map<string, string>; stored?: Set<string>; savedIds?: readonly string[]; collapsed?: boolean } = {},
): Draft {
  const values = opts.secretValues ?? new Map();
  const stored = opts.stored ?? new Set();
  const saved = new Set(opts.savedIds ?? []);
  return {
    name: cfg.name ?? '',
    root: cfg.root ?? '',
    env: envRows(cfg.env, '', values, stored),
    services: (cfg.services ?? []).map((s: ServiceConfig) => {
      const sh = shellText(s.command ?? []);
      return {
        key: newKey(),
        id: s.id ?? '',
        idAuto: false,
        origId: saved.has(s.id) ? s.id : null,
        name: s.name ?? '',
        cwd: s.cwd ?? '.',
        commandText: sh ? sh.text : joinArgv(s.command ?? []),
        viaShell: sh !== null,
        shell: sh?.shell ?? SHELL_PROGRAM,
        shellFlag: sh?.flag ?? SHELL_FLAG,
        env: envRows(s.env, s.id, values, stored),
        stopTimeoutSec: s.stopTimeoutSec === undefined ? '' : String(s.stopTimeoutSec),
        collapsed: opts.collapsed ?? false,
      };
    }),
  };
}

export function commandOf(s: Pick<DraftService, 'commandText' | 'viaShell' | 'shell' | 'shellFlag'>): { argv: string[]; error: string | null } {
  if (s.viaShell) {
    if (!s.commandText.trim()) return { argv: [], error: '启动命令不能为空' };
    return { argv: [s.shell, s.shellFlag, s.commandText], error: null };
  }
  const r = splitArgv(s.commandText);
  if (r.error) return r;
  if (r.argv.length === 0) return { argv: [], error: '启动命令不能为空' };
  return r;
}

export type BuildMode = 'save' | 'json';

export interface BuildResult {
  config: ProjectConfig;
  /** Local (pre-daemon) errors by issue path, e.g. "services[0].command". */
  errors: Record<string, string>;
}

function buildEnv(rows: EnvRow[], at: string, mode: BuildMode, errors: Record<string, string>): EnvMap | undefined {
  const out: EnvMap = {};
  let any = false;
  const seen = new Set<string>();
  for (const r of rows) {
    const name = r.name.trim();
    if (!name && !r.value) continue;
    if (!name) {
      errors[`${at}`] = '环境变量名不能为空';
      continue;
    }
    if (seen.has(name)) errors[`${at}.${name}`] = `重复的环境变量：${name}`;
    seen.add(name);
    any = true;
    if (!r.secret) out[name] = r.value;
    else if (r.value && mode === 'save') out[name] = { secret: true, value: r.value };
    else if (r.value || r.stored) out[name] = { secret: true };
    else {
      out[name] = { secret: true };
      if (mode === 'save') errors[`${at}.${name}`] = `请填写 ${name} 的值`;
    }
  }
  return any ? out : undefined;
}

export function buildConfig(d: Draft, mode: BuildMode = 'save'): BuildResult {
  const errors: Record<string, string> = {};
  const config: ProjectConfig = { schemaVersion: 1, name: d.name.trim(), root: d.root.trim(), services: [] };
  const penv = buildEnv(d.env, 'env', mode, errors);
  if (penv) config.env = penv;
  d.services.forEach((s, i) => {
    const at = `services[${i}]`;
    const cmd = commandOf(s);
    if (cmd.error) errors[`${at}.command`] = cmd.error;
    const svc: ServiceConfig = { id: s.id.trim(), name: s.name.trim(), cwd: s.cwd.trim() || '.', command: cmd.argv };
    const env = buildEnv(s.env, `${at}.env`, mode, errors);
    if (env) svc.env = env;
    if (s.stopTimeoutSec.trim()) {
      const n = Number(s.stopTimeoutSec);
      if (!Number.isInteger(n) || n < 1 || n > 300) errors[`${at}.stopTimeoutSec`] = '停止等待须为 1–300 的整数秒';
      else svc.stopTimeoutSec = n;
    }
    config.services.push(svc);
  });
  return { config, errors };
}

export interface ParsedJson {
  config: ProjectConfig | null;
  error: string | null;
  /** 1-based position of a syntax error */
  line?: number;
  column?: number;
}

/** Parse the JSON tab; report syntax errors with line/column. */
export function parseConfigJson(text: string): ParsedJson {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch (e) {
    const msg = (e as Error).message;
    let pos: number | null = null;
    const m1 = /position (\d+)/.exec(msg);
    if (m1) pos = Number(m1[1]);
    const m2 = /line (\d+) column (\d+)/.exec(msg);
    let line: number | undefined;
    let column: number | undefined;
    if (m2) {
      line = Number(m2[1]);
      column = Number(m2[2]);
    } else if (pos !== null) {
      const before = text.slice(0, pos);
      line = before.split('\n').length;
      column = pos - before.lastIndexOf('\n');
    }
    return { config: null, error: `JSON 语法错误：${msg}`, line, column };
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return { config: null, error: '顶层必须是对象' };
  const v = value as Record<string, unknown>;
  if (!Array.isArray(v.services)) return { config: null, error: '缺少 services 数组' };
  for (const [i, s] of (v.services as unknown[]).entries()) {
    if (typeof s !== 'object' || s === null) return { config: null, error: `services[${i}] 必须是对象` };
    const c = (s as Record<string, unknown>).command;
    if (c !== undefined && (!Array.isArray(c) || !c.every((x) => typeof x === 'string'))) {
      return { config: null, error: `services[${i}].command 必须是字符串数组（argv）` };
    }
  }
  return { config: value as ProjectConfig, error: null };
}
