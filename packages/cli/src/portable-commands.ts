import { realpathSync, statSync } from 'node:fs';
import type { Project, ProjectView, ValidateResult } from '@devpanel/contract';
import { api, ClientError } from './client.ts';
import { changedPaths, exportConfig, hideInputs, prepareImport, readConfigFile, saveExport } from './portable-config.ts';

export async function exportProject(id: string, file: string) {
  const project = await api<Project>(`/projects/${encodeURIComponent(id)}`);
  const document = exportConfig(project.config);
  saveExport(file, document);
  return { exported: true, file, requiredInputs: document.inputs, note: '共享前请审阅文件；本机输入另存且不要提交。导出不会修改项目。' };
}

export async function importProject(options: { file: string; root: string; inputs?: string; apply?: boolean; revision?: string; group?: string; instance?: string }) {
  const invalid = (message: string) => new ClientError({ error: { code: 'CONFIG_INVALID', message } });
  let root: string;
  try { root = realpathSync(options.root); if (!statSync(root).isDirectory()) throw invalid(''); }
  catch { throw invalid('请选择存在的本机项目目录'); }
  const document = readConfigFile(options.file);
  const values = options.inputs ? readConfigFile(options.inputs, 64 * 1024) : {};
  const prepared = prepareImport(document, root, values);
  if (options.group !== undefined || options.instance !== undefined) {
    if (!options.group || !options.instance) throw invalid('--group 与 --instance 必须同时提供');
    prepared.config.instance = { group: options.group, name: options.instance };
  }
  const projects = await api<ProjectView[]>('/projects');
  const found = projects.find(p => p.root === root);
  const existing = found ? await api<Project>(`/projects/${encodeURIComponent(found.id)}`) : undefined;
  const preview = {
    mode: existing ? 'update' : 'register', applied: false,
    projectId: existing?.id ?? null, revision: existing?.revision ?? null,
    name: prepared.config.name, root,
    requiredInputs: prepared.inputs, missingInputs: prepared.missing,
    changes: changedPaths(existing?.config, prepared.config),
    keptUserValues: existing?.config.params?.filter(p => p.setBy === 'user' && prepared.config.params?.some(next => next.key === p.key)).map(p => p.key) ?? [],
    validation: null as Pick<ValidateResult, 'ok' | 'issues'> | null,
    note: existing ? '仅预览；保存需 --apply --if-revision <本次 revision>，用户值保护仍生效。' : '仅预览；保存需 --apply。导入不会启动或重启项目。',
  };
  if (prepared.missing.length) {
    if (options.apply) throw invalid('缺少必需的本机输入，未保存；先运行不带 --apply 的导入查看所需输入');
    return { value: hideInputs(preview, values), code: 2 };
  }
  const validation = await api<ValidateResult>('/config/validate', 'POST', prepared.config);
  preview.validation = { ok: validation.ok, issues: validation.issues };
  if (!validation.ok || !options.apply) return { value: hideInputs(preview, values), code: validation.ok ? 0 : 2 };
  try {
    if (existing) {
      if (!options.revision || !/^[1-9]\d*$/.test(options.revision) || !Number.isSafeInteger(Number(options.revision))) throw invalid('更新必须传预览时的 --if-revision');
      const project = await api<Project & { keptUserValues?: string[] }>(`/projects/${encodeURIComponent(existing.id)}`, 'PUT', { ifRevision: Number(options.revision), config: prepared.config });
      return { value: { applied: true, projectId: project.id, revision: project.revision, mode: 'update', keptUserValues: project.keptUserValues ?? [] }, code: 0 };
    }
    if (options.revision !== undefined) throw invalid('该目录未登记，不能使用更新 revision；请重新预览');
    const result = await api<{ project: Project }>('/projects', 'POST', prepared.config);
    return { value: { applied: true, projectId: result.project.id, revision: result.project.revision, mode: 'register' }, code: 0 };
  } catch (error) {
    if (error instanceof ClientError) throw new ClientError(hideInputs(error.body, values));
    throw error;
  }
}
