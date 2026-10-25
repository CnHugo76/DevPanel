import { closeSync, constants, fstatSync, openSync, readSync, writeFileSync } from 'node:fs';
import { isAbsolute, relative } from 'node:path';
import type { ParamType, ParamValue, PortableConfigInput, PortableProjectConfig, ProjectConfig } from '@devpanel/contract';
import { ClientError } from './client.ts';

const invalid = (message: string) => new ClientError({ error: { code: 'CONFIG_INVALID', message } });
const object = (v: unknown): v is Record<string, any> => !!v && typeof v === 'object' && !Array.isArray(v);
const scalar = (v: unknown): v is ParamValue => typeof v === 'string' || typeof v === 'boolean' || (typeof v === 'number' && Number.isFinite(v));
const forbidden = new Set(['__proto__', 'prototype', 'constructor']);
const pointer = (v: string) => v.replace(/~/g, '~0').replace(/\//g, '~1');
const projectKeys = ['schemaVersion', 'name', 'instance', 'env', 'services', 'params', 'actions', 'maven', 'repositories', 'mavenProjects'];
const localPath = (v: unknown) => typeof v === 'string' && /(^|[=\s"'(:])(?:\/(?!\/)|~[\\/]|[a-zA-Z]:[\\/])|file:\/\//.test(v);

/** Bounded even if a file grows between opening and reading. Never include file contents in errors. */
export function readConfigFile(path: string, maxBytes = 1024 * 1024): unknown {
  let fd: number | undefined;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK);
    if (!fstatSync(fd).isFile()) throw invalid('配置必须是普通文件');
    const buffer = Buffer.alloc(maxBytes + 1);
    let size = 0, count: number;
    while (size < buffer.length && (count = readSync(fd, buffer, size, buffer.length - size, null)) > 0) size += count;
    if (size > maxBytes) throw invalid('配置文件超过大小限制');
    return JSON.parse(buffer.subarray(0, size).toString('utf8'));
  } catch (error) {
    if (error instanceof ClientError) throw error;
    throw invalid('无法读取有效 JSON 文件');
  } finally { if (fd !== undefined) closeSync(fd); }
}

function checkKeys(value: unknown, depth = 0): void {
  if (depth > 30) throw invalid('配置嵌套过深');
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    if (forbidden.has(key)) throw invalid('配置包含不允许的属性');
    checkKeys(child, depth + 1);
  }
}

/** Export only saved configuration. Response metadata, policies and history never enter the file. */
export function exportConfig(config: ProjectConfig): PortableProjectConfig {
  const project: any = {};
  for (const key of projectKeys) if (key in config) project[key] = structuredClone((config as any)[key]);
  checkKeys(project);
  if (!Array.isArray(project.services) || !project.services.length || (project.actions !== undefined && !Array.isArray(project.actions)) || (project.params !== undefined && !Array.isArray(project.params))) throw invalid('项目配置结构无效');
  const mavenMode = (value: unknown) => value === undefined || ['auto', 'wrapper', 'mvn'].includes(String(value));
  if (project.maven !== undefined && (!object(project.maven) || !mavenMode(project.maven.executable))) throw invalid('Maven executable 必须是 auto、wrapper 或 mvn');
  for (const scope of ['repositories', 'mavenProjects']) {
    if (project[scope] === undefined) continue;
    if (!Array.isArray(project[scope])) throw invalid('项目目标必须是数组');
    for (const target of project[scope]) {
      if (!object(target) || typeof target.path !== 'string' || localPath(target.path) || target.path.split(/[\\/]/).includes('..')) throw invalid('仓库和 Maven 工程必须使用项目内的相对路径');
      if (scope === 'mavenProjects' && !mavenMode(target.executable)) throw invalid('Maven executable 必须是 auto、wrapper 或 mvn');
    }
  }
  const inputs: PortableConfigInput[] = [];
  const input = (target: string, kind: 'secret' | 'path', valueType: ParamType = 'string') => {
    inputs.push({ id: `input${inputs.length + 1}`, target, kind, label: target, valueType });
  };
  const env = (values: any, target: string) => {
    for (const [key, value] of Object.entries(values ?? {})) {
      if (object(value) && value.secret === true) {
        values[key] = { secret: true };
        input(`${target}/${pointer(key)}/value`, 'secret');
      } else if (localPath(value)) {
        values[key] = '';
        input(`${target}/${pointer(key)}`, 'path');
      }
    }
  };
  env(project.env, '/env');
  for (const scope of ['services', 'actions']) {
    for (const [index, item] of (project[scope] ?? []).entries()) {
      if (!object(item) || typeof item.cwd !== 'string' || !Array.isArray(item.command) || !item.command.length || item.command.some((v: unknown) => typeof v !== 'string')) throw invalid('服务配置结构无效');
      const target = `/${scope}/${index}`;
      if (isAbsolute(item.cwd)) {
        const path = relative(config.root, item.cwd);
        if (path !== '..' && !path.startsWith('../') && !isAbsolute(path)) item.cwd = path || '.';
        else { item.cwd = ''; input(`${target}/cwd`, 'path'); }
      }
      item.command.forEach((arg: string, i: number) => {
        if (localPath(arg)) { item.command[i] = ''; input(`${target}/command/${i}`, 'path'); }
      });
      env(item.env, `${target}/env`);
    }
  }
  for (const [index, param] of (project.params ?? []).entries()) {
    if (!object(param)) throw invalid('参数配置结构无效');
    if (param.type === 'enum' && param.choices?.some((choice: any) => localPath(choice?.value))) throw invalid('本机路径枚举无法安全移植，请先将它改为 string 参数');
    for (const key of ['setBy', 'describedBy', 'valueUpdatedAt', 'usedBy']) delete param[key];
    if (param.secret) { delete param.value; input(`/params/${index}/value`, 'secret', param.type); }
    else if (localPath(param.value)) { delete param.value; input(`/params/${index}/value`, 'path', param.type); }
  }
  return { format: 'devpanel.project', version: 1, project, inputs };
}

/** A target is a known scalar slot, never an arbitrary pointer setter. */
function targetSlot(project: any, input: PortableConfigInput): { parent: any; key: string; type: ParamType } {
  if (!input.target.startsWith('/') || /~(?![01])/.test(input.target)) throw invalid('输入目标不是有效 JSON Pointer');
  const parts = input.target.slice(1).split('/').map(p => p.replace(/~1/g, '/').replace(/~0/g, '~'));
  if (parts.some(p => forbidden.has(p))) throw invalid('输入目标包含不允许的属性');
  const index = (array: unknown, key: string | undefined) => {
    if (!Array.isArray(array) || key === undefined || !/^(0|[1-9]\d*)$/.test(key) || !Number.isSafeInteger(Number(key)) || Number(key) >= array.length) throw invalid('输入目标不存在');
    return array[Number(key)];
  };
  let parent: any, key = '', type: ParamType = 'string', secret = false;
  if (parts[0] === 'params' && parts.length === 3 && parts[2] === 'value') {
    parent = index(project.params, parts[1]); key = 'value';
    if (!object(parent) || !['string', 'number', 'boolean', 'enum'].includes(parent.type)) throw invalid('输入参数类型无效');
    type = parent.type; secret = parent.secret === true;
  } else {
    let item = project, rest = parts;
    if (parts[0] === 'services' || parts[0] === 'actions') {
      item = index(project[parts[0]], parts[1]); rest = parts.slice(2);
      if (!object(item)) throw invalid('输入服务不存在');
      if (rest[0] === 'cwd' && rest.length === 1) { parent = item; key = 'cwd'; }
      else if (rest[0] === 'command' && rest.length === 2) {
        index(item.command, rest[1]); parent = item.command; key = rest[1]!;
      }
    }
    if (rest[0] === 'env' && (rest.length === 2 || rest.length === 3)) {
      if (!object(item.env) || !Object.hasOwn(item.env, rest[1]!)) throw invalid('输入环境变量不存在');
      if (rest.length === 2) { parent = item.env; key = rest[1]!; }
      else if (rest[2] === 'value' && object(item.env[rest[1]!]) && item.env[rest[1]!].secret === true) {
        parent = item.env[rest[1]!]; key = 'value'; secret = true;
      }
    }
    if (!parent || typeof key! !== 'string' || (!secret && typeof parent[key!] !== 'string')) throw invalid('输入目标不是允许的标量位置');
  }
  if (input.kind === 'secret' ? !secret : secret || !['string', 'enum'].includes(type)) throw invalid('输入种类与目标不匹配');
  if (input.valueType !== undefined && input.valueType !== type) throw invalid('输入类型与目标不匹配');
  return { parent, key: key!, type };
}

export function prepareImport(document: unknown, root: string, values: unknown = {}): { config: ProjectConfig; inputs: PortableConfigInput[]; missing: PortableConfigInput[] } {
  checkKeys(document); checkKeys(values);
  if (!object(document) || document.format !== 'devpanel.project' || document.version !== 1 || !object(document.project) || !Array.isArray(document.inputs)) throw invalid('不是受支持的 DevPanel 共享配置');
  if (Object.keys(document).some(k => !['format', 'version', 'project', 'inputs'].includes(k)) || Object.keys(document.project).some(k => !projectKeys.includes(k))) throw invalid('共享配置包含未知字段');
  if (!object(values) || Object.values(values).some(v => !scalar(v))) throw invalid('本机输入必须是 ID 到标量值的 JSON 对象');
  const project = structuredClone(document.project);
  const ids = new Set<string>(), targets = new Set<string>();
  const inputs: PortableConfigInput[] = [], missing: PortableConfigInput[] = [];
  for (const entry of document.inputs) {
    if (!object(entry) || typeof entry.id !== 'string' || !entry.id || forbidden.has(entry.id) || typeof entry.target !== 'string' || typeof entry.label !== 'string' || !['secret', 'path'].includes(entry.kind) || ids.has(entry.id) || targets.has(entry.target)) throw invalid('本机输入定义无效或重复');
    ids.add(entry.id); targets.add(entry.target);
    const input = entry as PortableConfigInput, slot = targetSlot(project, input);
    if (input.kind === 'secret' && Object.hasOwn(slot.parent, slot.key)) throw invalid('秘密值必须移到独立本机输入文件');
    inputs.push(input);
    if (!Object.hasOwn(values, input.id)) { missing.push(input); continue; }
    const value = values[input.id];
    const expected = ['string', 'enum'].includes(slot.type) ? 'string' : slot.type;
    if (typeof value !== expected || (typeof value === 'string' && (value.includes('\0') || (input.kind === 'path' && !value)))) throw invalid('本机输入值与目标类型不匹配');
    slot.parent[slot.key] = value;
  }
  if (Object.keys(values).some(k => !ids.has(k))) throw invalid('本机输入文件包含未声明的 ID');
  // Every secret placeholder must be explicitly declared. Omission must not silently retain a different machine's value.
  const required = exportConfig({ ...project, root } as ProjectConfig).inputs.filter(i => i.kind === 'secret');
  if (required.some(i => !targets.has(i.target))) throw invalid('秘密字段必须声明本机输入');
  return { config: { ...project, root } as ProjectConfig, inputs, missing };
}

export function saveExport(path: string, config: PortableProjectConfig): void {
  try { writeFileSync(path, JSON.stringify(config, null, 2) + '\n', { flag: 'wx', mode: 0o600 }); }
  catch { throw invalid('无法导出：目标文件已存在或目录不可写，请选择新文件'); }
}

/** Preview reports changed field paths, never old/new secret or local-input values. */
export function changedPaths(before: unknown, after: unknown, path = ''): string[] {
  if (/^\/params\/\d+\/(setBy|describedBy|valueUpdatedAt|usedBy)$/.test(path)) return [];
  if (JSON.stringify(before) === JSON.stringify(after)) return [];
  if (before && after && typeof before === 'object' && typeof after === 'object') {
    return [...new Set([...Object.keys(before), ...Object.keys(after)])].flatMap(k => changedPaths((before as any)[k], (after as any)[k], `${path}/${pointer(k)}`));
  }
  return [path || '/'];
}

export function hideInputs<T>(value: T, inputs: unknown): T {
  const strings = object(inputs) ? Object.values(inputs).filter((v): v is string => typeof v === 'string' && !!v).sort((a, b) => b.length - a.length) : [];
  const pattern = strings.length ? new RegExp(strings.map(v => v.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'g') : null;
  const walk = (item: any): any => typeof item === 'string' ? (pattern ? item.replace(pattern, '[LOCAL INPUT]') : item) : Array.isArray(item) ? item.map(walk) : object(item) ? Object.fromEntries(Object.entries(item).map(([k, v]) => [k, walk(v)])) : item;
  return walk(value);
}
