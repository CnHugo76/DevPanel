import type { ActionParamValue, DaemonInfo } from '@devpanel/contract';
import { api, ClientError } from './client.ts';
import { readConfigFile } from './portable-config.ts';

const invalid = (message: string) => new ClientError({ error: { code: 'BAD_REQUEST', message } });
export function hasActionParams(config: unknown): boolean {
  return !!config && typeof config === 'object' && Array.isArray((config as any).actions) && (config as any).actions.some((a: any) => a?.params?.length);
}
export async function requireActionParams(): Promise<void> {
  const info = await api<DaemonInfo>('/daemon');
  if (!info.capabilities?.includes('action-params-v1')) throw invalid('管理服务不支持操作参数，请先升级管理服务');
}
export async function readActionParams(json?: string, file?: string): Promise<Record<string, ActionParamValue> | undefined> {
  if (json !== undefined && file !== undefined) throw invalid('--params 与 --params-file 不能同时使用');
  if (json === undefined && file === undefined) return undefined;
  let value: unknown;
  try {
    if (file === '-') {
      const chunks: Buffer[] = []; let size = 0;
      for await (const chunk of process.stdin) { const b = Buffer.from(chunk); size += b.length; if (size > 1024 * 1024) throw invalid('操作参数超过 1 MiB'); chunks.push(b); }
      value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    } else if (file !== undefined) value = readConfigFile(file);
    else { if (Buffer.byteLength(json!) > 1024 * 1024) throw invalid('操作参数超过 1 MiB'); value = JSON.parse(json!); }
  } catch { throw invalid('无法读取操作参数 JSON 对象（内容不回显）'); }
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(k => ['__proto__', 'prototype', 'constructor'].includes(k))) throw invalid('操作参数必须为 JSON 对象');
  return value as Record<string, ActionParamValue>;
}
