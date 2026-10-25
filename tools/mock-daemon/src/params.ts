/**
 * Params (contract v1.1-A, api.md §3.1): placeholder parsing, validation, start-time
 * substitution with shell escaping, usage references, setter bookkeeping and inline write-back.
 * Pure functions over ProjectConfig; the engine owns storage, revisions and events.
 */
import path from 'node:path';
import type {
  EnvMap,
  ParamConfig,
  ParamReference,
  ParamSetter,
  ParamType,
  ParamValue,
  ProjectConfig,
  ServiceConfig,
  ValidationIssue,
} from '@devpanel/contract';
import { HttpError } from './errors.ts';
import { stableStringify } from './util.ts';

export const PARAM_KEY_RE = /^[a-zA-Z][a-zA-Z0-9_]{0,31}$/;
/** What a fragment that came from a secret param looks like in RunDetail.command and sys lines. */
export const MASK = '••••';
const PARAM_TYPES: ParamType[] = ['string', 'number', 'boolean', 'enum'];
const SHELL_NAMES = new Set(['sh', 'bash', 'zsh']);
/** Response-only fields; ignored when they appear in requests. */
const RESPONSE_ONLY = ['setBy', 'valueUpdatedAt', 'describedBy', 'usedBy'] as const;

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

// ───────────── placeholders ─────────────

export type Token = { kind: 'lit'; raw: string; text: string } | { kind: 'ref'; raw: string; key: string };

/**
 * Split a string into literal text and ${key} references. "$${" is a literal "${".
 * "${...}" whose content is not a valid key (e.g. "${a:-b}") or that is never closed stays literal text.
 */
export function tokenize(s: string): Token[] {
  const out: Token[] = [];
  let text = '';
  let raw = '';
  const flush = () => {
    if (raw) out.push({ kind: 'lit', raw, text });
    text = '';
    raw = '';
  };
  let i = 0;
  while (i < s.length) {
    if (s.startsWith('$${', i)) {
      text += '${';
      raw += '$${';
      i += 3;
      continue;
    }
    if (s.startsWith('${', i)) {
      const end = s.indexOf('}', i + 2);
      const key = end === -1 ? '' : s.slice(i + 2, end);
      if (end !== -1 && PARAM_KEY_RE.test(key)) {
        flush();
        out.push({ kind: 'ref', raw: s.slice(i, end + 1), key });
        i = end + 1;
        continue;
      }
    }
    text += s[i];
    raw += s[i];
    i++;
  }
  flush();
  return out;
}

export function refsIn(s: string): string[] {
  return tokenize(s).flatMap((t) => (t.kind === 'ref' ? [t.key] : []));
}

/** Escape a literal so it survives tokenize() unchanged ("${" → "$${"). */
function escapeLiteral(s: string): string {
  return s.replaceAll('${', () => '$${'); // function form: '$$' in a replacement string means '$'
}

export function formatValue(v: ParamValue | undefined): string {
  if (v === undefined) return '';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') {
    const s = String(v);
    return /e/i.test(s) ? v.toLocaleString('en-US', { useGrouping: false, maximumFractionDigits: 20 }) : s;
  }
  return v;
}

/** POSIX single-quote: the result is exactly one literal word for sh/bash/zsh. */
export function shellQuote(s: string): string {
  return `'${s.replaceAll("'", `'\\''`)}'`;
}

/**
 * Index of the shell script argument when argv is a shell invocation
 * (basename of command[0] is sh/bash/zsh and some later arg is "-c" or a short option group ending in "c"),
 * else -1. Only that script argument gets quoted substitutions; positional args after it are plain argv.
 */
export function shellScriptIndex(command: readonly string[]): number {
  if (!command.length || !SHELL_NAMES.has(path.basename(command[0] ?? ''))) return -1;
  for (let i = 1; i < command.length; i++) {
    if (/^-[A-Za-z]*c$/.test(command[i]!)) return i + 1 < command.length ? i + 1 : -1;
  }
  return -1;
}

// ───────────── references ─────────────

export interface RefSite {
  key: string;
  ref: ParamReference;
  /** Validation path, e.g. "services[0].command[2]". */
  path: string;
}

/** Every ${key} site in commands and non-secret env values. Tolerates unvalidated input. */
export function collectRefs(cfg: unknown): RefSite[] {
  const out: RefSite[] = [];
  if (!isObj(cfg)) return out;
  const scanEnv = (env: unknown, serviceId: string, at: string) => {
    if (!isObj(env)) return;
    for (const [k, v] of Object.entries(env)) {
      if (typeof v !== 'string') continue; // secret env values are literal
      for (const key of new Set(refsIn(v))) out.push({ key, ref: { serviceId, where: 'env', envKey: k }, path: `${at}.${k}` });
    }
  };
  scanEnv(cfg.env, '*', 'env');
  for (const section of ['services', 'actions'] as const) {
    if (!Array.isArray(cfg[section])) continue;
    cfg[section].forEach((s: unknown, i: number) => {
      if (!isObj(s)) return;
      const sid = typeof s.id === 'string' ? `${section === 'actions' ? 'action:' : ''}${s.id}` : '';
      if (Array.isArray(s.command)) {
        s.command.forEach((a: unknown, j: number) => {
          if (typeof a !== 'string') return;
          for (const key of new Set(refsIn(a))) out.push({ key, ref: { serviceId: sid, where: 'command', index: j }, path: `${section}[${i}].command[${j}]` });
        });
      }
      scanEnv(s.env, sid, `${section}[${i}].env`);
      if (section === 'services' && isObj(s.ready) && isObj(s.ready.check) && s.ready.check.kind === 'port' && typeof s.ready.check.port === 'string') for (const key of refsIn(s.ready.check.port)) out.push({ key, ref: { serviceId: sid, where: 'ready' }, path: `${section}[${i}].ready.check.port` });
    });
  }
  return out;
}

export function usedByMap(cfg: ProjectConfig): Map<string, ParamReference[]> {
  const m = new Map<string, ParamReference[]>();
  for (const site of collectRefs(cfg)) {
    const list = m.get(site.key) ?? [];
    list.push(site.ref);
    m.set(site.key, list);
  }
  return m;
}

// ───────────── validation ─────────────

/** Why `value` is not acceptable for `def`, or null. Does not look at secret-ness. */
export function checkParamValue(def: Pick<ParamConfig, 'type' | 'choices' | 'min' | 'max'>, value: unknown): string | null {
  switch (def.type) {
    case 'string':
      return typeof value === 'string' ? null : '值必须是字符串';
    case 'boolean':
      return typeof value === 'boolean' ? null : '值必须是 true 或 false';
    case 'number':
      if (typeof value !== 'number' || !Number.isFinite(value)) return '值必须是数字';
      if (typeof def.min === 'number' && value < def.min) return `值 ${value} 小于最小值 ${def.min}`;
      if (typeof def.max === 'number' && value > def.max) return `值 ${value} 大于最大值 ${def.max}`;
      return null;
    case 'enum': {
      if (typeof value !== 'string') return '值必须是字符串（可选值之一）';
      const ok = Array.isArray(def.choices) && def.choices.some((c) => isObj(c) && c.value === value);
      return ok ? null : `值 ${value} 不在可选值中`;
    }
    default:
      return '类型不合法';
  }
}

/**
 * Param checks of /config/validate (and register/update).
 * existingSecretParams: keys with a stored secret value; null = standalone validation (missing secret value accepted).
 */
export function validateParams(input: Record<string, unknown>, issues: ValidationIssue[], existingSecretParams: Set<string> | null): void {
  const err = (p: string, message: string, code: 'PARAM_INVALID' | 'PARAM_UNKNOWN' = 'PARAM_INVALID') =>
    issues.push({ path: p, severity: 'error', code, message });
  const keys = new Map<string, number>();
  const raw = input.params;
  if (raw !== undefined && !Array.isArray(raw)) {
    err('params', '选项必须是数组');
  } else if (Array.isArray(raw)) {
    raw.forEach((p: unknown, i: number) => {
      const at = `params[${i}]`;
      if (!isObj(p)) return err(at, '选项必须是对象');
      if (typeof p.key !== 'string' || !PARAM_KEY_RE.test(p.key)) {
        err(`${at}.key`, 'key 须以字母开头，只含字母、数字和下划线，最长 32 位');
      } else if (keys.has(p.key)) {
        err(`${at}.key`, `选项 key 重复：${p.key}`);
      } else keys.set(p.key, i);
      if (typeof p.label !== 'string' || !p.label.trim()) err(`${at}.label`, '选项名称不能为空');
      if (p.description !== undefined && typeof p.description !== 'string') err(`${at}.description`, '说明必须是字符串');
      if (p.secret !== undefined && typeof p.secret !== 'boolean') err(`${at}.secret`, 'secret 必须是布尔值');
      if (typeof p.type !== 'string' || !PARAM_TYPES.includes(p.type as ParamType)) {
        return err(`${at}.type`, '类型须为 string / number / boolean / enum');
      }
      const type = p.type as ParamType;
      if (type === 'enum') {
        if (!Array.isArray(p.choices) || p.choices.length === 0) err(`${at}.choices`, '单选选项至少需要一个可选值');
        else {
          const seen = new Set<string>();
          p.choices.forEach((c: unknown, j: number) => {
            if (!isObj(c) || typeof c.value !== 'string') return err(`${at}.choices[${j}]`, '可选值须为 { value: string, label?, description? }');
            if (seen.has(c.value)) err(`${at}.choices[${j}].value`, `可选值重复：${c.value}`);
            seen.add(c.value);
            if (c.label !== undefined && typeof c.label !== 'string') err(`${at}.choices[${j}].label`, '标签必须是字符串');
            if (c.description !== undefined && typeof c.description !== 'string') err(`${at}.choices[${j}].description`, '说明必须是字符串');
          });
        }
      } else if (p.choices !== undefined) err(`${at}.choices`, '只有单选（enum）选项可以有可选值');
      if (type === 'number') {
        for (const f of ['min', 'max'] as const) {
          if (p[f] !== undefined && (typeof p[f] !== 'number' || !Number.isFinite(p[f]))) err(`${at}.${f}`, `${f} 必须是数字`);
        }
        if (typeof p.min === 'number' && typeof p.max === 'number' && p.min > p.max) err(`${at}.min`, 'min 不能大于 max');
      } else if (p.min !== undefined || p.max !== undefined) err(`${at}.min`, '只有数字选项可以设置 min / max');
      if (p.value === undefined) {
        if (p.secret !== true) err(`${at}.value`, '缺少值');
        else if (existingSecretParams && !(typeof p.key === 'string' && existingSecretParams.has(p.key))) {
          err(`${at}.value`, `${String(p.key)} 没有已保存的值，不能“保持不变”`);
        }
      } else {
        const why = checkParamValue({ type, choices: p.choices as ParamConfig['choices'], min: p.min as number, max: p.max as number }, p.value);
        if (why) err(`${at}.value`, why);
      }
    });
  }
  const sites = collectRefs(input);
  const used = new Set<string>();
  for (const s of sites) {
    used.add(s.key);
    if (!keys.has(s.key)) err(s.path, `引用了不存在的选项 \${${s.key}}`, 'PARAM_UNKNOWN');
  }
  for (const [key, i] of keys) {
    if (!used.has(key)) {
      issues.push({ path: `params[${i}]`, severity: 'warning', code: 'WARN_PARAM_UNUSED', message: `选项 ${key} 没有被任何命令或环境变量引用` });
    }
  }
}

// ───────────── substitution ─────────────

export interface Rendered {
  actual: string;
  display: string;
  used: string[];
  unknown: string[];
}

function render(s: string, params: Map<string, ParamConfig>, shell: boolean): Rendered {
  let actual = '';
  let display = '';
  const used: string[] = [];
  const unknown: string[] = [];
  for (const t of tokenize(s)) {
    if (t.kind === 'lit') {
      actual += t.text;
      display += t.text;
      continue;
    }
    const p = params.get(t.key);
    if (!p) {
      unknown.push(t.key);
      actual += t.raw;
      display += t.raw;
      continue;
    }
    used.push(t.key);
    const v = formatValue(p.value);
    const piece = shell ? shellQuote(v) : v;
    actual += piece;
    display += p.secret ? MASK : piece;
  }
  return { actual, display, used, unknown };
}

export interface Substitution {
  /** argv actually executed. */
  command: string[];
  /** argv with secret-param fragments replaced by MASK (RunDetail.command, sys lines). */
  display: string[];
  /** Effective env (project ← service), real values. Never leaves the engine. */
  env: Record<string, string>;
  /** Same keys; values that carry secrets (secret env or secret params) are MASK. Safe for simulated logs. */
  displayEnv: Record<string, string>;
  envKeys: string[];
  /** RunDetail.params: params this service's run used; secret as {secret:true}. */
  params: Record<string, ParamValue | { secret: true }>;
}

function paramMap(cfg: ProjectConfig): Map<string, ParamConfig> {
  const list: unknown[] = Array.isArray(cfg.params) ? cfg.params : [];
  return new Map(list.filter((p): p is ParamConfig => isObj(p) && typeof p.key === 'string').map((p) => [p.key, p]));
}

export function substituteService(cfg: ProjectConfig, svc: ServiceConfig): Substitution {
  const params = paramMap(cfg);
  const used = new Set<string>();
  const scriptIdx = shellScriptIndex(svc.command);
  const command: string[] = [];
  const display: string[] = [];
  svc.command.forEach((a, i) => {
    const r = render(a, params, i === scriptIdx);
    r.used.forEach((k) => used.add(k));
    command.push(r.actual);
    display.push(r.display);
  });
  const merged: EnvMap = { ...(cfg.env ?? {}), ...(svc.env ?? {}) };
  const env: Record<string, string> = {};
  const displayEnv: Record<string, string> = {};
  for (const [k, v] of Object.entries(merged)) {
    if (typeof v !== 'string') {
      env[k] = v.value ?? '';
      displayEnv[k] = MASK;
      continue;
    }
    const r = render(v, params, false);
    r.used.forEach((x) => used.add(x));
    env[k] = r.actual;
    displayEnv[k] = r.used.some((x) => params.get(x)?.secret) ? MASK : r.actual;
  }
  const out: Substitution['params'] = {};
  for (const p of cfg.params ?? []) {
    if (!used.has(p.key)) continue;
    out[p.key] = p.secret ? { secret: true } : (p.value as ParamValue);
  }
  return { command, display, env, displayEnv, envKeys: Object.keys(merged), params: out };
}

/**
 * Copy of the config with placeholders in command[*] and non-secret env values substituted
 * using non-secret values only (used for program / PATH resolution during validation).
 * Returns `blocked` service ids whose command[0] or PATH depends on a secret or unknown param.
 */
export function resolvableConfig(cfg: ProjectConfig): { cfg: ProjectConfig; blocked: Set<string> } {
  const params = new Map([...paramMap(cfg)].filter(([, p]) => !p.secret && p.value !== undefined));
  const blocked = new Set<string>();
  const env = (e: EnvMap | undefined, sid: string | null): EnvMap | undefined => {
    if (!isObj(e)) return e;
    const o: EnvMap = {};
    for (const [k, v] of Object.entries(e)) {
      if (typeof v !== 'string') {
        o[k] = v;
        continue;
      }
      const r = render(v, params, false);
      if (k === 'PATH' && r.unknown.length && sid !== null) blocked.add(sid);
      o[k] = r.actual;
    }
    return o;
  };
  const out: ProjectConfig = { ...cfg };
  const penv = env(cfg.env, null);
  if (penv) out.env = penv;
  const projectPathBlocked = typeof cfg.env?.PATH === 'string' && render(cfg.env.PATH, params, false).unknown.length > 0;
  if (Array.isArray(cfg.services)) {
    out.services = cfg.services.map((s) => {
      if (!isObj(s) || !Array.isArray(s.command)) return s;
      const sid = String(s.id);
      const cmd = s.command.map((a, i) => {
        if (typeof a !== 'string') return a;
        const r = render(a, params, false);
        if (i === 0 && r.unknown.length) blocked.add(sid);
        return r.actual;
      });
      const m: ServiceConfig = { ...s, command: cmd };
      const se = env(s.env, sid);
      if (se) m.env = se;
      if (projectPathBlocked && !(isObj(s.env) && 'PATH' in s.env)) blocked.add(sid);
      return m;
    });
  }
  return { cfg: out, blocked };
}

// ───────────── response shaping ─────────────

export function stripResponseOnly(p: ParamConfig): ParamConfig {
  const o: ParamConfig = { ...p };
  for (const f of RESPONSE_ONLY) delete o[f];
  return o;
}

/** Response form: no secret value, usedBy computed. */
export function publicParams(cfg: ProjectConfig): ParamConfig[] | undefined {
  if (!cfg.params) return undefined;
  const used = usedByMap(cfg);
  return cfg.params.map((p) => {
    const o: ParamConfig = { ...p, usedBy: used.get(p.key) ?? [] };
    if (p.secret) delete o.value;
    if (p.choices) o.choices = p.choices.map((c) => ({ ...c }));
    return o;
  });
}

// ───────────── setter bookkeeping ─────────────

export function setterOf(client: string | null | undefined): ParamSetter {
  return client === 'cli' ? 'agent' : 'user';
}

function descriptive(p: ParamConfig): string {
  return stableStringify({ label: p.label, description: p.description, choices: p.choices, min: p.min, max: p.max });
}

/**
 * Combine incoming params (request) with stored ones: keep stored secret values for keep-markers,
 * record setBy / valueUpdatedAt / describedBy, and protect values last set by a user.
 * onIncompatible: what to do when a protected user value is invalid under the incoming definition
 * ('throw' → 422 telling the agent to pass overrideUserValues; 'incoming' → let the incoming value win).
 */
export function mergeParams(
  incoming: ParamConfig[] | undefined,
  existing: ParamConfig[] | undefined,
  setter: ParamSetter,
  opts: { override: boolean; now: string; onIncompatible: 'throw' | 'incoming' },
): { params: ParamConfig[] | undefined; kept: string[] } {
  const kept: string[] = [];
  if (incoming === undefined) return { params: undefined, kept };
  const old = new Map((existing ?? []).map((p) => [p.key, p]));
  const params = incoming.map((raw, i) => {
    const p = stripResponseOnly(raw);
    const o = old.get(p.key);
    if (!o) return { ...p, setBy: setter, valueUpdatedAt: opts.now, describedBy: setter };
    if (p.secret && p.value === undefined) p.value = o.value;
    let setBy = o.setBy ?? setter;
    let valueUpdatedAt = o.valueUpdatedAt ?? opts.now;
    const changed = stableStringify(p.value) !== stableStringify(o.value);
    if (changed) {
      const protect = o.setBy === 'user' && !opts.override && o.value !== undefined;
      const why = protect ? checkParamValue(p, o.value) : null;
      if (protect && why && opts.onIncompatible === 'throw') {
        throw new HttpError(422, 'CONFIG_INVALID', `选项 ${p.key} 的值由用户设置，不能按新的定义保留（${why}）；确需覆盖请传 overrideUserValues: true`, {
          issues: [{ path: `params[${i}].value`, severity: 'error', code: 'PARAM_INVALID', message: `用户设置的值 ${formatValue(o.value)} ${why}` }],
        });
      }
      if (protect && !why) {
        p.value = o.value;
        kept.push(p.key);
      } else {
        setBy = setter;
        valueUpdatedAt = opts.now;
      }
    }
    const describedBy = descriptive(p) !== descriptive(o) ? setter : (o.describedBy ?? setter);
    return { ...p, setBy, valueUpdatedAt, describedBy };
  });
  return { params, kept };
}

// ───────────── delete with write-back ─────────────

function replaceRef(s: string, key: string, replacement: string): string {
  return tokenize(s)
    .map((t) => (t.kind === 'ref' && t.key === key ? escapeLiteral(replacement) : t.raw))
    .join('');
}

/**
 * Write the current value of `key` back into every reference, then drop the param.
 * Commands: inside a shell script argument the value is written quoted (same as start-time substitution).
 * Env: a non-secret param is written into the string; a secret param turns that env entry into a
 * secret env value holding the fully substituted string (secret env values are literal).
 * Caller must refuse secret params referenced by a command.
 */
export function inlineParam(cfg: ProjectConfig, key: string): ProjectConfig {
  const params = paramMap(cfg);
  const p = params.get(key);
  if (!p) return cfg;
  const v = formatValue(p.value);
  const env = (e: EnvMap | undefined): EnvMap | undefined => {
    if (!e) return e;
    const o: EnvMap = {};
    for (const [k, val] of Object.entries(e)) {
      if (typeof val !== 'string' || !refsIn(val).includes(key)) {
        o[k] = val;
        continue;
      }
      o[k] = p.secret ? { secret: true, value: render(val, params, false).actual } : replaceRef(val, key, v);
    }
    return o;
  };
  const out: ProjectConfig = { ...cfg, params: (cfg.params ?? []).filter((x) => x.key !== key) };
  const penv = env(cfg.env);
  if (penv) out.env = penv;
  if (cfg.actions) out.actions = inlineParam({ ...cfg, actions: undefined, services: cfg.actions }, key).services;
  out.services = cfg.services.map((s) => {
    const script = shellScriptIndex(s.command);
    const m: ServiceConfig = { ...s, command: s.command.map((a, i) => replaceRef(a, key, i === script ? shellQuote(v) : v)) };
    if (s.ready?.check.kind === "port" && s.ready.check.port === `${"${"}${key}}`) m.ready = { ...s.ready, check: { kind: "port", port: p.value as number } };
    const se = env(s.env);
    if (se) m.env = se;
    return m;
  });
  return out;
}
