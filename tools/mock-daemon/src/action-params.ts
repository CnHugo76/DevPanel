import { basename } from 'node:path';
import type { ActionConfig, ActionParamConfig, ActionParamSnapshot, ActionParamValue, ErrorCode, ProjectConfig, ServiceConfig, ValidationIssue } from '@devpanel/contract';

// Mock implementation of v1.6-A. Keep it independent from the daemon runtime.

const keyPattern = /^[a-zA-Z][a-zA-Z0-9_]{0,31}$/;
const forbidden = new Set(['__proto__', 'prototype', 'constructor']);
const object = (v: unknown): v is Record<string, any> => !!v && typeof v === 'object' && !Array.isArray(v);
const text = (v: unknown): v is string => typeof v === 'string' && !v.includes('\0');
export const secretMarker = (v: unknown): v is { secret: true } => object(v) && v.secret === true && Object.keys(v).length === 1;
export type ActionValues = Record<string, { value?: ActionParamValue; secret?: boolean }>;

export function actionValueText(value: ActionParamValue | undefined): string {
  if (value === undefined) return '';
  if (Array.isArray(value)) return JSON.stringify(value);
  const s = String(value);
  if (typeof value !== 'number' || !s.includes('e')) return s;
  const [m, e] = s.split('e'), negative = m!.startsWith('-');
  const parts = m!.replace('-', '').split('.'), digits = parts.join(''), point = parts[0]!.length + Number(e);
  return (negative ? '-' : '') + (point <= 0 ? '0.' + '0'.repeat(-point) + digits : point >= digits.length ? digits + '0'.repeat(point - digits.length) : digits.slice(0, point) + '.' + digits.slice(point));
}

/** Constant messages deliberately omit submitted values. */
export function actionValueIssue(p: ActionParamConfig, value: unknown): string | undefined {
  if (value === undefined) return p.required ? '请填写此参数' : undefined;
  if (p.type === 'boolean') return typeof value === 'boolean' ? undefined : '值必须为布尔值';
  if (p.type === 'number') return typeof value !== 'number' || !Number.isFinite(value) ? '值必须为有限数字' : (p.min !== undefined && value < p.min) || (p.max !== undefined && value > p.max) ? '值超出允许范围' : undefined;
  if (p.type === 'multiselect') {
    if (!Array.isArray(value) || value.some(v => !text(v)) || new Set(value).size !== value.length) return '请选择不重复的候选项';
    if (p.required && !value.length) return '请至少选择一项';
    return value.some(v => !Array.isArray(p.choices) || !p.choices.some(c => object(c) && c.value === v)) ? '包含未定义的候选项' : undefined;
  }
  if (!text(value)) return '值必须为文本';
  if (p.required && !value.trim()) return '请填写此参数';
  if (p.type === 'enum' && (!Array.isArray(p.choices) || !p.choices.some(c => object(c) && c.value === value))) return '请选择已定义的候选项';
  return undefined;
}

export function actionReferences(value: string): string[] {
  return [...value.matchAll(/\$\$\{|\$\{action\.([a-zA-Z][a-zA-Z0-9_]{0,31})\}/g)].flatMap(m => m[1] ? [m[1]] : []);
}

export function actionDefinitionIssues(input: unknown, previous?: ProjectConfig, save = false): ValidationIssue[] {
  if (!object(input) || !Array.isArray(input.actions)) return [];
  const issues: ValidationIssue[] = [];
  const add = (path: string, message: string, code: ValidationIssue['code'] = 'PARAM_INVALID', severity: 'error' | 'warning' = 'error') => issues.push({ path, message, code, severity });
  input.actions.forEach((a: unknown, i: number) => {
    if (!object(a)) return;
    const at = `actions[${i}]`;
    if (a.runLabel !== undefined && (!text(a.runLabel) || !a.runLabel.trim())) add(at + '.runLabel', '请输入运行按钮文字');
    if (a.params !== undefined && !Array.isArray(a.params)) { add(at + '.params', '操作参数必须为数组'); return; }
    const keys = new Set<string>(), used = new Set<string>();
    for (const [j, raw] of (a.params ?? []).entries()) {
      const p = raw as ActionParamConfig, path = `${at}.params[${j}]`;
      if (!object(p)) { add(path, '参数必须为对象'); continue; }
      if (!text(p.key) || !keyPattern.test(p.key) || forbidden.has(p.key) || keys.has(p.key)) add(path + '.key', '参数 key 无效或重复');
      keys.add(p.key);
      if (!text(p.label) || !p.label.trim()) add(path + '.label', '请输入参数名称');
      if (p.description !== undefined && !text(p.description)) add(path + '.description', '说明必须为文本');
      for (const flag of ['secret', 'required'] as const) if (p[flag] !== undefined && typeof p[flag] !== 'boolean') add(path + '.' + flag, '必须为布尔值');
      if (!['string', 'number', 'boolean', 'enum', 'multiselect'].includes(p.type)) add(path + '.type', '参数类型无效');
      if (p.type === 'enum' || p.type === 'multiselect') {
        if (!Array.isArray(p.choices) || !p.choices.length || p.choices.some(c => !object(c) || !text(c.value) || !c.value || (c.label !== undefined && !text(c.label)) || (c.description !== undefined && !text(c.description))) || new Set(p.choices?.map(c => c?.value)).size !== p.choices?.length) add(path + '.choices', '需要非空、无重复的候选项');
      } else if (p.choices !== undefined) add(path + '.choices', '仅枚举支持候选项');
      for (const f of ['min', 'max'] as const) if (p[f] !== undefined && (p.type !== 'number' || typeof p[f] !== 'number' || !Number.isFinite(p[f]))) add(path + '.' + f, '范围必须为有限数字');
      if (p.min !== undefined && p.max !== undefined && p.min > p.max) add(path, 'min 不得大于 max');
      if (p.default !== undefined) {
        let value: unknown = p.default;
        if (secretMarker(value)) {
          if (!p.secret) add(path + '.default', '仅敏感参数可保持默认值');
          const old = previous?.actions?.find(x => x.id === a.id)?.params?.find(x => x.key === p.key && x.secret)?.default;
          if (!save && old === undefined) continue;
          value = old;
          if (value === undefined || secretMarker(value)) { add(path + '.default', '没有可保持的敏感默认值'); continue; }
        }
        const why = actionValueIssue(p, value);
        if (why) add(path + '.default', why);
      }
    }
    const check = (value: unknown, path: string, allowed: boolean) => {
      if (typeof value !== 'string') return;
      for (const key of actionReferences(value)) {
        used.add(key);
        if (!allowed) add(path, '此字段不支持操作参数');
        else if (!keys.has(key)) add(path, '引用了未定义的操作参数', 'PARAM_UNKNOWN');
      }
    };
    if (Array.isArray(a.command)) a.command.forEach((v: unknown, j: number) => check(v, `${at}.command[${j}]`, j > 0));
    for (const [key, v] of Object.entries(object(a.env) ? a.env : {})) check(v, `${at}.env.${key}`, true);
    for (const field of ['cwd', 'name', 'description', 'id', 'runLabel']) check(a[field], `${at}.${field}`, false);
    (a.params ?? []).forEach((p: ActionParamConfig, j: number) => { if (object(p) && typeof p.key === 'string' && !used.has(p.key)) add(`${at}.params[${j}]`, '操作参数未被引用', 'WARN_PARAM_UNUSED', 'warning'); });
  });
  return issues;
}

export function keepActionDefaults(config: ProjectConfig, previous?: ProjectConfig): void {
  for (const a of config.actions ?? []) for (const p of a.params ?? []) if (p.secret && secretMarker(p.default)) {
    const old = previous?.actions?.find(x => x.id === a.id)?.params?.find(x => x.key === p.key && x.secret)?.default;
    if (old !== undefined && !secretMarker(old)) p.default = structuredClone(old);
  }
}
export function maskAction(a: ActionConfig): ActionConfig {
  const result = structuredClone(a);
  for (const p of result.params ?? []) if (p.secret && p.default !== undefined) p.default = { secret: true };
  return result;
}
export function actionDefaultValues(a: ActionConfig): ActionValues {
  return Object.fromEntries((a.params ?? []).map(p => [p.key, { secret: p.secret, value: secretMarker(p.default) ? undefined : p.default }]));
}
export function actionSensitive(values: ActionValues): string[] {
  const raw = Object.values(values).flatMap(p => p.secret && p.value !== undefined ? [actionValueText(p.value), ...(Array.isArray(p.value) ? p.value : [String(p.value)])] : []).filter(Boolean);
  return [...new Set(raw.flatMap(v => [v, JSON.stringify(v).slice(1, -1)]))];
}
export function actionConfigSecrets(config: unknown): string[] {
  if (!object(config) || !Array.isArray(config.actions)) return [];
  return config.actions.flatMap((a: any) => object(a) && Array.isArray(a.params) ? a.params.flatMap((p: any) => object(p) && p.secret && (typeof p.default === 'string' || typeof p.default === 'boolean' || (typeof p.default === 'number' && Number.isFinite(p.default)) || (Array.isArray(p.default) && p.default.every(text))) ? actionSensitive({ value: { secret: true, value: p.default } }) : []) : []).filter(Boolean);
}

export class ActionInputError extends Error {
  code: ErrorCode;
  status: number;
  details?: Record<string, unknown>;
  constructor(code: ErrorCode, message: string, status: number, details?: Record<string, unknown>) { super(message); this.code = code; this.status = status; this.details = details; }
}
export function resolveActionRun(a: ActionConfig, input: unknown, revision: number): { values: ActionValues; snapshot: ActionParamSnapshot[]; sensitive: string[] } {
  const data = input === undefined ? {} : input;
  if (!object(data) || Object.keys(data).some(k => !['params', 'ifRevision'].includes(k)) || (data.params !== undefined && !object(data.params)) || (data.ifRevision !== undefined && (!Number.isSafeInteger(data.ifRevision) || data.ifRevision < 1))) throw new ActionInputError('BAD_REQUEST', '操作参数请求格式无效', 400);
  if (data.ifRevision !== undefined && data.ifRevision !== revision) throw new ActionInputError('REVISION_MISMATCH', '项目配置已变更，请刷新后复核参数', 409);
  const issues: ValidationIssue[] = [], values = actionDefaultValues(a), overrides = data.params ?? {};
  for (const key of Object.keys(overrides)) if (forbidden.has(key) || !Object.hasOwn(values, key)) issues.push({ path: `params.${key}`, severity: 'error', code: 'PARAM_UNKNOWN', message: '未定义的操作参数' });
  const snapshot: ActionParamSnapshot[] = [];
  for (const p of a.params ?? []) {
    let value = Object.hasOwn(overrides, p.key) ? overrides[p.key] : values[p.key]?.value;
    const why = actionValueIssue(p, value);
    if (why) issues.push({ path: `params.${p.key}`, severity: 'error', code: 'PARAM_INVALID', message: why });
    if (!why && Array.isArray(value)) value = p.choices!.filter(c => value.includes(c.value)).map(c => c.value);
    values[p.key] = { secret: p.secret, value: value === undefined ? undefined : structuredClone(value) };
    snapshot.push({ key: p.key, label: p.label, type: p.type, ...(p.description === undefined ? {} : { description: p.description }), value: value === undefined ? null : p.secret ? { secret: true } : structuredClone(value), ...(!p.secret && p.choices ? { choices: structuredClone(p.choices.filter(c => Array.isArray(value) ? value.includes(c.value) : value === c.value)) } : {}) });
  }
  if (issues.length) throw new ActionInputError('CONFIG_INVALID', '操作参数校验失败', 422, { issues });
  return { values, snapshot, sensitive: actionSensitive(values) };
}

/** Both namespaces are scanned together; inserted text is never scanned again. */
function render(text: string, config: ProjectConfig, values: ActionValues | undefined, shell: boolean, masked: boolean): string {
  const pattern = values ? /\$\$\{|\$\{(?:([a-zA-Z][a-zA-Z0-9_]{0,31})|action\.([a-zA-Z][a-zA-Z0-9_]{0,31}))\}/g : /\$\$\{|\$\{([a-zA-Z][a-zA-Z0-9_]{0,31})\}/g;
  let context = '', escaped = false, cursor = 0;
  return text.replace(pattern, (match: string, ...args: any[]) => {
    const key = args[0] as string | undefined, actionKey = values ? args[1] as string | undefined : undefined;
    const offset = args[values ? 2 : 1] as number;
    for (const c of text.slice(cursor, offset)) { if (escaped) escaped = false; else if (c === '\\' && context !== "'") escaped = true; else if (c === context) context = ''; else if (!context && (c === "'" || c === '"')) context = c; }
    cursor = offset + match.length;
    if (!key && !actionKey) return '${';
    const p = actionKey ? values?.[actionKey] : config.params?.find(p => p.key === key);
    if (!p) return match;
    if (key && p.value === undefined) return match;
    let value = masked && p.secret && p.value !== undefined ? '••••' : actionValueText(p.value);
    if (shell) {
      const quoted = "'" + value.replaceAll("'", "'\\''") + "'";
      // Pair a pending source backslash so it cannot escape the quote we insert.
      value = (escaped ? '\\' : '') + (context ? context + quoted + context : quoted);
      escaped = false;
    }
    return value;
  });
}
export function expandAction(config: ProjectConfig, action: ActionConfig, values: ActionValues, masked = false): ServiceConfig {
  const pre = action.command.map(v => render(v, config, values, false, masked));
  const flag = ['sh', 'bash', 'zsh'].includes(basename(pre[0]!)) ? pre.findIndex((v, i) => i > 0 && /^-[a-zA-Z]*c$/.test(v)) : -1;
  const env = { ...config.env, ...action.env };
  for (const [key, value] of Object.entries(env)) if (typeof value === 'string') env[key] = render(value, config, Object.hasOwn(action.env ?? {}, key) ? values : undefined, false, masked);
  return { ...action, env, command: action.command.map((v, i) => render(v, config, i > 0 ? values : undefined, flag >= 0 && i === flag + 1, masked)) };
}
