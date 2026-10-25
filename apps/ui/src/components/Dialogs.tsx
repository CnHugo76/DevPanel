import { useEffect, useState } from 'react';
import type { Project } from '@devpanel/contract';
import { ApiRequestError, api } from '../api/client';
import { agentRules } from '../lib/rules';
import { isActiveState } from '../lib/status';
import { copyText, ensureConfig, openDialog, runAction, toast, useApp, type Dialog } from '../store/app';
import { Modal } from './common';

export function Dialogs() {
  const dialog = useApp((s) => s.dialog);
  if (!dialog || dialog.kind === 'daemon') return null;
  const close = () => openDialog(null);
  switch (dialog.kind) {
    case 'remove':
      return <RemoveDialog projectId={dialog.projectId} onClose={close} />;
    case 'rules':
      return <RulesDialog projectId={dialog.projectId} onClose={close} />;
    case 'json':
      return <JsonDialog projectId={dialog.projectId} onClose={close} />;
    case 'force':
      return <ForceDialog dialog={dialog} onClose={close} />;
  }
}

function RemoveDialog({ projectId, onClose }: { projectId: string; onClose: () => void }) {
  const project = useApp((s) => s.projects.find((p) => p.id === projectId));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!project) return null;
  const running = project.services.some((s) => isActiveState(s.state) || s.state === 'unknown');
  const remove = async () => {
    setBusy(true);
    setError(null);
    try {
      await api.remove(projectId);
      toast(`已移除 ${project.name}（未删除任何文件）`);
      onClose();
    } catch (e) {
      const err = e instanceof ApiRequestError ? e.error : null;
      setError(err?.code === 'PROJECT_RUNNING' ? '项目有服务正在运行，请先停止再移除。' : (err?.message ?? String(e)));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Modal
      title={`移除项目 ${project.name}？`}
      onClose={onClose}
      footer={
        <>
          <button className="b" onClick={onClose} data-autofocus>
            取消
          </button>
          <button className="b danger solid" onClick={() => void remove()} disabled={busy || running}>
            {busy ? '移除中…' : '移除'}
          </button>
        </>
      }
    >
      <p>
        只从面板移除配置和日志，不会删除 <span className="mono">{project.root}</span> 下任何文件。
      </p>
      {running && <p className="hint bad">项目有服务正在运行，请先停止再移除。</p>}
      {error && <p className="hint bad">{error}</p>}
    </Modal>
  );
}

function RulesDialog({ projectId, onClose }: { projectId: string; onClose: () => void }) {
  const text = agentRules(projectId);
  return (
    <Modal
      title="Agent 规则"
      wide
      onClose={onClose}
      footer={
        <>
          <button className="b" onClick={onClose}>
            关闭
          </button>
          <button className="b primary" data-autofocus onClick={() => void copyText(text, '已复制 Agent 规则')}>
            复制
          </button>
        </>
      }
    >
      <p>把下面这段合并到项目现有的 Agent 规则文件（如 AGENTS.md）中，不要覆盖整个文件。它是协作约定，不是操作系统级的权限隔离。</p>
      <pre className="codebox">{text}</pre>
    </Modal>
  );
}

function JsonDialog({ projectId, onClose }: { projectId: string; onClose: () => void }) {
  const revision = useApp((s) => s.projects.find((p) => p.id === projectId)?.revision ?? 0);
  const [project, setProject] = useState<Project | null>(null);
  useEffect(() => {
    void ensureConfig(projectId, revision).then(setProject);
  }, [projectId, revision]);
  const text = project ? JSON.stringify(project.config, null, 2) : '';
  return (
    <Modal
      title={`配置 JSON${project ? ` · r${project.revision}` : ''}`}
      wide
      onClose={onClose}
      footer={
        <>
          <button className="b" onClick={onClose}>
            关闭
          </button>
          <button className="b primary" data-autofocus disabled={!project} onClick={() => void copyText(text, '已复制配置 JSON')}>
            复制
          </button>
        </>
      }
    >
      <p>敏感值已遮盖为 {'{"secret": true}'}。修改请使用「⚙ 配置」或 CLI 的 project update。</p>
      <pre className="codebox" style={{ maxHeight: 420, overflow: 'auto' }}>
        {project ? text : '读取中…'}
      </pre>
    </Modal>
  );
}

function ForceDialog({ dialog, onClose }: { dialog: Extract<Dialog, { kind: 'force' }>; onClose: () => void }) {
  const project = useApp((s) => s.projects.find((p) => p.id === dialog.projectId));
  const stats = useApp((s) => s.stats?.projects[dialog.projectId]);
  if (!project) return null;
  const targets = project.services.filter((s) => (dialog.serviceIds ? dialog.serviceIds.includes(s.id) : true) && s.currentRun);
  let count: number | null = 0;
  for (const s of targets) {
    const st = stats?.services[s.id];
    if (st && st.runId === s.currentRun?.id && st.processCount !== null) count += st.processCount;
    else count = null;
    if (count === null) break;
  }
  const what = count !== null && count > 0 ? `${count} 个受管进程` : '全部受管进程';
  const name = targets.length === 1 && project.services.length > 1 ? `「${targets[0]!.name}」` : '';
  return (
    <Modal
      title="强制停止？"
      onClose={onClose}
      footer={
        <>
          <button className="b" onClick={onClose} data-autofocus>
            取消
          </button>
          <button
            className="b danger solid"
            onClick={() => {
              onClose();
              void runAction(dialog.projectId, 'force-stop', dialog.serviceIds);
            }}
          >
            强制停止
          </button>
        </>
      }
    >
      <p>
        将向{name}本次运行的 {what}发送 SIGKILL，可能丢失未保存的数据。
      </p>
      <p className="hint">只会作用于能核验属于本次运行的进程（PID + 启动时间一致）。</p>
    </Modal>
  );
}
