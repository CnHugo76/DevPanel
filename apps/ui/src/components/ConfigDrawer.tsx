import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import type { ConfigDiffEntry, Project, ProjectConfig, ServiceResolution, ValidateResult, ValidationIssue } from '@devpanel/contract';
import { ApiRequestError, api } from '../api/client';
import { detectBackground } from '../lib/argv';
import {
  SECRET_NAME,
  SERVICE_ID_RE,
  buildConfig,
  commandOf,
  draftFromConfig,
  emptyDraft,
  emptyEnvRow,
  emptyService,
  parseConfigJson,
  secretValuesOf,
  slugify,
  storedSecretsOf,
  type Draft,
  type DraftService,
  type EnvRow,
} from '../lib/draft';
import { isActiveState } from '../lib/status';
import { openDrawer, selectProject, storeConfig, toast, useApp, type DrawerState } from '../store/app';
import { Modal } from './common';

type Banner =
  | { kind: 'revision'; revision: number | null }
  | { kind: 'conflict'; projectId: string | null; diff: ConfigDiffEntry[]; message: string }
  | { kind: 'error'; message: string; list?: string[] };

interface Validation {
  result: ValidateResult;
  /** draft service keys in the order they were sent (issue paths use these indexes) */
  sentKeys: string[];
  sentIds: string[];
}

interface Confirm {
  title: string;
  body: React.ReactNode;
  confirmText: string;
  danger?: boolean;
  onConfirm: () => void;
  onCancel?: () => void;
}

const CIRCLED = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];

function issuesUnder(issues: ValidationIssue[], prefix: string): ValidationIssue[] {
  return issues.filter((i) => i.path === prefix || i.path.startsWith(`${prefix}.`) || i.path.startsWith(`${prefix}[`));
}

export function ConfigDrawer({ state }: { state: DrawerState }) {
  const editId = state.mode === 'edit' ? state.projectId : null;
  const uid = useId();
  const view = useApp((s) => (editId ? s.projects.find((p) => p.id === editId) : undefined));
  const [original, setOriginal] = useState<Project | null>(null);
  const [draft, setDraft] = useState<Draft>(() => emptyDraft());
  const [loaded, setLoaded] = useState(state.mode === 'create');
  const [initialJson, setInitialJson] = useState<string>(() => JSON.stringify(buildConfig(emptyDraft(), 'json').config));
  const [tab, setTab] = useState<'form' | 'json'>('form');
  const [jsonText, setJsonText] = useState('');
  const [jsonError, setJsonError] = useState<{ message: string; line?: number; column?: number } | null>(null);
  const [validation, setValidation] = useState<Validation | null>(null);
  const [localErrors, setLocalErrors] = useState<Record<string, string>>({});
  const [banner, setBanner] = useState<Banner | null>(null);
  const [saving, setSaving] = useState(false);
  const [confirm, setConfirm] = useState<Confirm | null>(null);
  const validateSeq = useRef(0);
  const lastValidated = useRef('');
  const jsonRef = useRef<HTMLTextAreaElement>(null);
  const draftRef = useRef(draft);
  draftRef.current = draft;

  const running = !!view && view.services.some((s) => isActiveState(s.state) || s.state === 'unknown');
  const stored = useMemo(() => storedSecretsOf(original?.config ?? null), [original]);
  const savedIds = useMemo(() => original?.config.services.map((s) => s.id) ?? [], [original]);

  const load = useCallback(async () => {
    if (!editId) return;
    try {
      const proj = await api.project(editId);
      if (proj.id !== editId) return;
      storeConfig(proj);
      setOriginal(proj);
      const d = draftFromConfig(proj.config, {
        stored: storedSecretsOf(proj.config),
        savedIds: proj.config.services.map((s) => s.id),
        collapsed: proj.config.services.length > 2,
      });
      setDraft(d);
      setInitialJson(JSON.stringify(buildConfig(d, 'json').config));
      setLoaded(true);
      setBanner(null);
      setValidation(null);
      setLocalErrors({});
      setTab('form');
      lastValidated.current = '';
    } catch (e) {
      setBanner({ kind: 'error', message: `读取配置失败：${e instanceof ApiRequestError ? e.error.message : String(e)}` });
    }
  }, [editId]);

  useEffect(() => {
    void load();
  }, [load]);

  const dirty = loaded && (JSON.stringify(buildConfig(draft, 'json').config) !== initialJson || secretValuesOf(draft).size > 0 || (tab === 'json' && jsonText !== ''));

  const close = useCallback(() => {
    if (dirty) {
      setConfirm({ title: '放弃未保存的修改？', body: '关闭后，本次在抽屉中的修改不会保存。', confirmText: '放弃修改', danger: true, onConfirm: () => openDrawer(null) });
    } else openDrawer(null);
  }, [dirty]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !confirm) {
        e.preventDefault();
        close();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [close, confirm]);

  // ── validation on blur ──
  const runValidate = useCallback(
    (cfg: ProjectConfig, sentKeys: string[]) => {
      const json = JSON.stringify(cfg);
      if (json === lastValidated.current) return;
      lastValidated.current = json;
      const seq = ++validateSeq.current;
      api
        .validate(cfg)
        .then((result) => {
          if (seq !== validateSeq.current) return; // stale response
          setValidation({ result, sentKeys, sentIds: cfg.services.map((s) => s.id) });
        })
        .catch(() => {
          if (seq === validateSeq.current) lastValidated.current = '';
        });
    },
    [],
  );
  const onFormBlur = () => {
    // after the blur, so the latest keystroke is in the draft
    setTimeout(() => {
      const d = draftRef.current;
      if (!d.root.trim()) return; // nothing meaningful to resolve yet
      runValidate(buildConfig(d, 'json').config, d.services.map((s) => s.key));
    }, 0);
  };
  const onJsonBlur = () => {
    const parsed = parseConfigJson(jsonText);
    if (parsed.config) runValidate(parsed.config, []);
  };

  // ── tabs ──
  const toJson = () => {
    const errs = Object.entries(buildConfig(draft, 'save').errors).filter(([k]) => k.endsWith('.command'));
    if (errs.length) {
      setBanner({ kind: 'error', message: '启动命令无法解析，修正后才能切换到 JSON', list: errs.map(([, v]) => v) });
      return;
    }
    setJsonText(JSON.stringify(buildConfig(draft, 'json').config, null, 2));
    setJsonError(null);
    setTab('json');
  };
  const parseJsonToDraft = (): Draft | null => {
    const parsed = parseConfigJson(jsonText);
    if (!parsed.config) {
      setJsonError({ message: parsed.error ?? 'JSON 无效', line: parsed.line, column: parsed.column });
      if (parsed.line && jsonRef.current) {
        const lines = jsonText.split('\n');
        const pos = lines.slice(0, parsed.line - 1).reduce((a, l) => a + l.length + 1, 0) + Math.max(0, (parsed.column ?? 1) - 1);
        jsonRef.current.focus();
        jsonRef.current.setSelectionRange(pos, pos + 1);
      }
      return null;
    }
    setJsonError(null);
    const prevByIndex = draft.services;
    const next = draftFromConfig(parsed.config, { secretValues: secretValuesOf(draft), stored, savedIds });
    next.services.forEach((s, i) => {
      const prev = prevByIndex.find((p) => p.id === s.id) ?? prevByIndex[i];
      if (prev) s.collapsed = prev.collapsed;
    });
    return next;
  };
  const toForm = () => {
    const next = parseJsonToDraft();
    if (!next) return;
    setDraft(next);
    setTab('form');
  };

  // ── save ──
  const save = async () => {
    let d = draft;
    if (tab === 'json') {
      const next = parseJsonToDraft();
      if (!next) return;
      d = next;
      setDraft(next);
    }
    const { config, errors } = buildConfig(d, 'save');
    if (!config.name) errors.name = '项目名称不能为空';
    if (!config.root) errors.root = '根目录不能为空';
    else if (!config.root.startsWith('/')) errors.root = '根目录必须是绝对路径';
    const ids = new Set<string>();
    config.services.forEach((s, i) => {
      if (!s.name) errors[`services[${i}].name`] = '服务名称不能为空';
      if (!SERVICE_ID_RE.test(s.id)) errors[`services[${i}].id`] = 'ID 须为小写字母开头，只含小写字母、数字和连字符，最长 32 位';
      else if (ids.has(s.id)) errors[`services[${i}].id`] = `服务 ID 重复：${s.id}`;
      ids.add(s.id);
    });
    if (config.services.length === 0) errors.services = '至少需要一个服务';
    setLocalErrors(errors);
    if (Object.keys(errors).length) {
      setBanner({ kind: 'error', message: '请先修正标出的问题', list: tab === 'json' ? Object.entries(errors).map(([k, v]) => `${k}：${v}`) : undefined });
      return;
    }
    setSaving(true);
    setBanner(null);
    const sentKeys = d.services.map((s) => s.key);
    try {
      if (!editId) {
        const res = await api.register(config);
        storeConfig(res.project);
        selectProject(res.project.id);
        toast(res.created ? `已添加项目 ${res.project.config.name} · 未启动` : '该目录已以相同配置注册，已打开已有项目');
        openDrawer(null);
      } else {
        const proj = await api.update(editId, { ifRevision: original?.revision ?? 0, config });
        if (proj.id !== editId) return;
        storeConfig(proj);
        toast(running ? '已保存 · 下次启动时生效' : '已保存');
        openDrawer(null);
      }
    } catch (e) {
      if (!(e instanceof ApiRequestError)) {
        setBanner({ kind: 'error', message: String(e) });
        return;
      }
      const err = e.error;
      const details = (err.details ?? {}) as Record<string, unknown>;
      if (err.code === 'REVISION_MISMATCH') {
        setBanner({ kind: 'revision', revision: typeof details.revision === 'number' ? details.revision : null });
      } else if (err.code === 'CONFIG_CONFLICT') {
        setBanner({
          kind: 'conflict',
          projectId: typeof details.projectId === 'string' ? details.projectId : null,
          diff: Array.isArray(details.diff) ? (details.diff as ConfigDiffEntry[]) : [],
          message: err.message,
        });
      } else if (err.code === 'CONFIG_INVALID') {
        const issues = Array.isArray(details.issues) ? (details.issues as ValidationIssue[]) : [];
        setValidation({ result: { ok: false, issues, services: validation?.result.services ?? [] }, sentKeys, sentIds: config.services.map((s) => s.id) });
        setBanner({
          kind: 'error',
          message: '管理服务校验未通过，未保存',
          list: tab === 'json' ? issues.filter((i) => i.severity === 'error').map((i) => `${i.path}：${i.message}`) : undefined,
        });
      } else {
        setBanner({ kind: 'error', message: err.message });
      }
    } finally {
      setSaving(false);
    }
  };

  const loadLatest = () =>
    setConfirm({
      title: '载入最新配置？',
      body: '将丢弃你在抽屉中尚未保存的修改，改为显示管理服务中的最新配置。',
      confirmText: '丢弃并载入',
      danger: true,
      onConfirm: () => void load(),
    });

  // ── issue helpers (map validation paths → current cards) ──
  const issues = validation?.result.issues ?? [];
  const svcPrefix = (key: string): string | null => {
    const i = validation?.sentKeys.indexOf(key) ?? -1;
    return i >= 0 ? `services[${i}]` : null;
  };
  const resolutionFor = (key: string): ServiceResolution | null => {
    if (!validation) return null;
    const i = validation.sentKeys.indexOf(key);
    if (i < 0) return null;
    const id = validation.sentIds[i];
    return validation.result.services.find((r) => r.serviceId === id) ?? null;
  };
  const fieldIssues = (path: string | null, exact = false): ValidationIssue[] => {
    if (!path) return [];
    return exact ? issues.filter((i) => i.path === path) : issuesUnder(issues, path);
  };
  /** Paths that some form field renders (so they are not repeated in the "other" list). */
  const onField = (path: string): boolean => {
    if (/^(name|root|env)(\.|$)/.test(path)) return true;
    const m = /^services\[(\d+)\]\.(id|name|cwd|command|env|stopTimeoutSec)/.exec(path);
    if (!m) return false;
    const key = validation?.sentKeys[Number(m[1])];
    return !!key && draft.services.some((s) => s.key === key && !s.collapsed);
  };

  const update = (fn: (d: Draft) => Draft) => setDraft((d) => fn(d));
  const updateSvc = (key: string, patch: Partial<DraftService>) =>
    update((d) => ({ ...d, services: d.services.map((s) => (s.key === key ? { ...s, ...patch } : s)) }));

  const title = editId ? `编辑项目 · ${view?.name ?? original?.config.name ?? ''}` : '添加项目';

  const formBody = (
    <div onBlur={onFormBlur}>
      <div className="row2">
        <div className="f">
          <label htmlFor={`${uid}-name`}>
            项目名称 <i>*</i>
          </label>
          <input id={`${uid}-name`} className={`in${localErrors.name ? ' invalid' : ''}`} value={draft.name} onChange={(e) => update((d) => ({ ...d, name: e.target.value }))} data-autofocus aria-label="项目名称" />
          <FieldHints local={localErrors.name} issues={fieldIssues('name')} />
        </div>
        <div className="f">
          <label htmlFor={`${uid}-root`}>
            根目录 <i>*</i>
          </label>
          <input
            id={`${uid}-root`}
            className={`in mono${localErrors.root ? ' invalid' : ''}`}
            value={draft.root}
            aria-label="根目录"
            placeholder="/Users/you/Project/foo"
            onChange={(e) => update((d) => ({ ...d, root: e.target.value }))}
            spellCheck={false}
          />
          <FieldHints local={localErrors.root} issues={fieldIssues('root')} />
          {validation && draft.root && !issuesUnder(issues, 'root').length && !localErrors.root && <div className="hint ok">✓ 目录存在</div>}
        </div>
      </div>
      <details open={draft.env.length > 0}>
        <summary>项目级环境变量（所有服务共享；服务内同名变量优先）</summary>
        <EnvTable rows={draft.env} onChange={(env) => update((d) => ({ ...d, env }))} />
        <FieldHints local={Object.entries(localErrors).filter(([k]) => k.startsWith('env')).map(([, v]) => v).join('；') || undefined} issues={fieldIssues('env')} />
      </details>
      {draft.services.map((s, i) => (
        <ServiceCard
          key={s.key}
          svc={s}
          index={i}
          count={draft.services.length}
          prefix={svcPrefix(s.key)}
          localPrefix={`services[${i}]`}
          localErrors={localErrors}
          fieldIssues={fieldIssues}
          resolution={resolutionFor(s.key)}
          serviceView={s.origId ? view?.services.find((v) => v.id === s.origId) : undefined}
          takenIds={draft.services.filter((x) => x.key !== s.key).map((x) => x.id)}
          onChange={(patch) => updateSvc(s.key, patch)}
          onMove={(delta) =>
            update((d) => {
              const arr = [...d.services];
              const j = i + delta;
              if (j < 0 || j >= arr.length) return d;
              [arr[i], arr[j]] = [arr[j]!, arr[i]!];
              return { ...d, services: arr };
            })
          }
          onRemove={() => update((d) => ({ ...d, services: d.services.filter((x) => x.key !== s.key) }))}
          askConfirm={setConfirm}
        />
      ))}
      <button
        className="b"
        onClick={() => update((d) => ({ ...d, services: [...d.services, emptyService(d.services.map((x) => x.id))] }))}
      >
        ＋ 添加服务
      </button>
      {localErrors.services && <div className="hint bad">✕ {localErrors.services}</div>}
    </div>
  );

  // issues that no field above displayed
  const rest = tab === 'form' ? issues.filter((i) => !onField(i.path)) : issues;

  return (
    <>
      <div className="scrim" onMouseDown={close} />
      <aside className="drawer" role="dialog" aria-label={title}>
        <div className="dhead">
          <h3>
            {title}
            <button className="x" onClick={close} aria-label="关闭">
              ✕
            </button>
          </h3>
          <div className="tabs" role="tablist">
            <button role="tab" aria-selected={tab === 'form'} className={tab === 'form' ? 'on' : ''} onClick={() => tab !== 'form' && toForm()}>
              表单
            </button>
            <button role="tab" aria-selected={tab === 'json'} className={tab === 'json' ? 'on' : ''} onClick={() => tab !== 'json' && toJson()}>
              JSON
            </button>
          </div>
        </div>
        {banner && <DrawerBanner banner={banner} onLoadLatest={loadLatest} onDismiss={() => setBanner(null)} />}
        <div className="dbody">
          {!loaded ? (
            <div className="hint">正在读取配置…</div>
          ) : tab === 'form' ? (
            formBody
          ) : (
            <div>
              <textarea
                ref={jsonRef}
                className={`in mono jsonbox${jsonError ? ' invalid' : ''}`}
                value={jsonText}
                spellCheck={false}
                onChange={(e) => {
                  setJsonText(e.target.value);
                  setJsonError(null);
                }}
                onBlur={onJsonBlur}
                aria-label="配置 JSON"
              />
              {jsonError && (
                <div className="hint bad">
                  ✕ {jsonError.line ? `第 ${jsonError.line} 行第 ${jsonError.column ?? '?'} 列 · ` : ''}
                  {jsonError.message}（修正后才能切回表单或保存）
                </div>
              )}
              <div className="hint">与表单是同一份数据（ProjectConfig）。敏感值显示为 {'{"secret": true}'}：表单中已输入的新值会被保留，写 {'{"secret": true, "value": "…"}'} 可设置新值。</div>
            </div>
          )}
          {rest.length > 0 && (
            <div className="f" style={{ marginTop: 12 }}>
              <div className="lbl">其他校验结果</div>
              {rest.map((i, k) => (
                <div key={k} className={`hint ${i.severity === 'error' ? 'bad' : 'warn'}`}>
                  {i.severity === 'error' ? '✕' : '⚠'} {i.path ? <span className="mono">{i.path}</span> : null} {i.message}
                </div>
              ))}
            </div>
          )}
        </div>
        <div className="dfoot">
          <span className="note">{running ? '项目运行中：保存后在下次启动时生效，不会自动重启' : ''}</span>
          <button className="b" onClick={close}>
            取消
          </button>
          <button className="b primary" onClick={() => void save()} disabled={saving || !loaded}>
            {saving ? '保存中…' : '保存'}
          </button>
        </div>
      </aside>
      {confirm && (
        <Modal
          title={confirm.title}
          onClose={() => {
            confirm.onCancel?.();
            setConfirm(null);
          }}
          footer={
            <>
              <button
                className="b"
                onClick={() => {
                  confirm.onCancel?.();
                  setConfirm(null);
                }}
              >
                取消
              </button>
              <button
                className={`b ${confirm.danger ? 'danger solid' : 'primary'}`}
                data-autofocus
                onClick={() => {
                  setConfirm(null);
                  confirm.onConfirm();
                }}
              >
                {confirm.confirmText}
              </button>
            </>
          }
        >
          {confirm.body}
        </Modal>
      )}
    </>
  );
}

function DrawerBanner({ banner, onLoadLatest, onDismiss }: { banner: Banner; onLoadLatest: () => void; onDismiss: () => void }) {
  if (banner.kind === 'revision') {
    return (
      <div className="dbanner" role="alert">
        <div>
          <b>配置已被其他客户端（可能是 AI）修改</b>
          {banner.revision !== null ? `，当前版本 r${banner.revision}` : ''}。你的修改尚未保存。
        </div>
        <div className="row">
          <button className="b sm" onClick={onLoadLatest}>
            载入最新配置
          </button>
          <button className="link" onClick={onDismiss}>
            暂不处理
          </button>
        </div>
      </div>
    );
  }
  if (banner.kind === 'conflict') {
    return (
      <div className="dbanner" role="alert">
        <div>
          <b>该根目录已注册为另一个项目，且配置不同。</b>不会覆盖已有配置；如需修改，请打开已有项目后编辑。
        </div>
        {banner.diff.length > 0 && (
          <ul>
            {banner.diff.slice(0, 6).map((d) => (
              <li key={d.path} className="mono" style={{ fontSize: 11.5 }}>
                {d.path}: {JSON.stringify(d.existing)} → {JSON.stringify(d.incoming)}
              </li>
            ))}
            {banner.diff.length > 6 && <li>… 共 {banner.diff.length} 处不同</li>}
          </ul>
        )}
        {banner.projectId && (
          <div className="row">
            <button
              className="b sm"
              onClick={() => {
                selectProject(banner.projectId);
                openDrawer(null);
              }}
            >
              打开已有项目
            </button>
          </div>
        )}
      </div>
    );
  }
  return (
    <div className="dbanner bad" role="alert">
      <div>{banner.message}</div>
      {banner.list && (
        <ul>
          {banner.list.map((l, i) => (
            <li key={i}>{l}</li>
          ))}
        </ul>
      )}
    </div>
  );
}

function FieldHints({ local, issues }: { local?: string | undefined; issues: ValidationIssue[] }) {
  return (
    <>
      {local && <div className="hint bad">✕ {local}</div>}
      {issues
        .filter((i) => i.message !== local)
        .map((i, k) => (
        <div key={k} className={`hint ${i.severity === 'error' ? 'bad' : 'warn'}`}>
          {i.severity === 'error' ? '✕' : '⚠'} {i.message}
        </div>
      ))}
    </>
  );
}

function ServiceCard({
  svc,
  index,
  count,
  prefix,
  localPrefix,
  localErrors,
  fieldIssues,
  resolution,
  serviceView,
  takenIds,
  onChange,
  onMove,
  onRemove,
  askConfirm,
}: {
  svc: DraftService;
  index: number;
  count: number;
  prefix: string | null;
  localPrefix: string;
  localErrors: Record<string, string>;
  fieldIssues: (path: string | null, exact?: boolean) => ValidationIssue[];
  resolution: ServiceResolution | null;
  serviceView: { state: string; lastRun: unknown; name: string } | undefined;
  takenIds: string[];
  onChange: (patch: Partial<DraftService>) => void;
  onMove: (delta: number) => void;
  onRemove: () => void;
  askConfirm: (c: Confirm) => void;
}) {
  const uid = useId();
  const cmd = commandOf(svc);
  const bg = svc.commandText ? detectBackground(svc.commandText) : null;
  const p = (f: string) => (prefix ? `${prefix}.${f}` : null);
  const cmdIssues = fieldIssues(p('command')).filter((i) => !(bg && i.code === 'WARN_BACKGROUND_COMMAND'));
  const activeSvc = serviceView && ['starting', 'running', 'stopping', 'unknown'].includes(serviceView.state);
  const idChangedWithRuns = svc.origId !== null && svc.id !== svc.origId && !!serviceView?.lastRun;
  const le = (f: string) => localErrors[`${localPrefix}.${f}`];
  const resolutionHint = (() => {
    if (!resolution) return null;
    if (!resolution.cwdExists) return <div className="hint bad">✕ 工作目录不存在：{resolution.cwdAbs}</div>;
    if (resolution.programResolved) return <div className="hint ok">✓ 将执行 {resolution.programResolved} · 目录存在</div>;
    return (
      <div className="hint bad">
        ✕ 在 PATH 中找不到 {resolution.program}（当前 PATH：{resolution.pathUsed}）
      </div>
    );
  })();
  const shownCmdIssues = resolution ? cmdIssues.filter((i) => i.code !== 'COMMAND_NOT_FOUND') : cmdIssues;
  const cwdIssues = fieldIssues(p('cwd')).filter((i) => !(resolution && i.code === 'CWD_UNAVAILABLE'));

  return (
    <div className="card">
      <div className="ch">
        <span className="title" onClick={() => onChange({ collapsed: !svc.collapsed })} title={svc.collapsed ? '展开' : '折叠'}>
          <span style={{ color: 'var(--text-3)', fontSize: 10 }}>{svc.collapsed ? '▶' : '▼'}</span>
          {CIRCLED[index] ?? `${index + 1}.`} {svc.name || '未命名服务'}
        </span>
        <span className="idnote">id: {svc.id || '—'}</span>
        <span className="sp" />
        <button className="ib" onClick={() => onMove(-1)} disabled={index === 0} title="上移（启动顺序提前）" aria-label="上移">
          ↑
        </button>
        <button className="ib" onClick={() => onMove(1)} disabled={index === count - 1} title="下移" aria-label="下移">
          ↓
        </button>
        <button
          className="ib"
          onClick={onRemove}
          disabled={count === 1 || !!activeSvc}
          title={activeSvc ? '运行中的服务不能删除，请先停止' : count === 1 ? '至少需要一个服务' : '删除服务'}
          aria-label="删除服务"
        >
          ✕
        </button>
      </div>
      {(le('command') || shownCmdIssues.some((i) => i.severity === 'error') || (resolution && !resolution.programResolved)) && svc.collapsed && (
        <div className="hint bad">✕ 此服务有需要处理的问题，展开查看</div>
      )}
      {!svc.collapsed && (
        <div className="cbody">
          <div className="row2">
            <div className="f">
              <label htmlFor={`${uid}-name`}>
                名称 <i>*</i>
              </label>
              <input
                id={`${uid}-name`}
                className={`in${le('name') ? ' invalid' : ''}`}
                value={svc.name}
                aria-label="服务名称"
                onChange={(e) => {
                  const name = e.target.value;
                  onChange(svc.idAuto ? { name, id: slugify(name || 'service', takenIds) } : { name });
                }}
              />
              <FieldHints local={le('name')} issues={fieldIssues(p('name'))} />
            </div>
            <div className="f">
              <label htmlFor={`${uid}-id`}>
                ID <i>*</i>
              </label>
              <input
                id={`${uid}-id`}
                className={`in mono${le('id') || (svc.id && !SERVICE_ID_RE.test(svc.id)) ? ' invalid' : ''}`}
                value={svc.id}
                aria-label="服务 ID"
                onChange={(e) => onChange({ id: e.target.value, idAuto: false })}
                onBlur={() => {
                  if (idChangedWithRuns) {
                    askConfirm({
                      title: '修改服务 ID？',
                      body: (
                        <p>
                          「{serviceView?.name}」已有运行记录。修改 ID 等同于删除原服务 <span className="mono">{svc.origId}</span> 并新建服务{' '}
                          <span className="mono">{svc.id}</span>：保存后原服务的运行记录与日志不再属于这个服务。
                        </p>
                      ),
                      confirmText: '仍要修改',
                      danger: true,
                      onConfirm: () => {},
                      onCancel: () => onChange({ id: svc.origId! }),
                    });
                  }
                }}
                spellCheck={false}
              />
              <FieldHints local={le('id')} issues={fieldIssues(p('id'))} />
              {!le('id') && svc.id && !SERVICE_ID_RE.test(svc.id) && <div className="hint bad">✕ 小写字母开头，只含小写字母、数字和连字符</div>}
            </div>
          </div>
          <div className="f">
            <label htmlFor={`${uid}-cwd`}>工作目录（相对根目录）</label>
            <input id={`${uid}-cwd`} className="in mono" value={svc.cwd} aria-label="工作目录" placeholder="." onChange={(e) => onChange({ cwd: e.target.value })} spellCheck={false} />
            <FieldHints issues={cwdIssues} />
          </div>
          <div className="f">
            <label htmlFor={`${uid}-command`}>
              启动命令 <i>*</i>
            </label>
            <input
              id={`${uid}-command`}
              className={`in mono${le('command') ? ' invalid' : ''}`}
              value={svc.commandText}
              aria-label="启动命令"
              placeholder="例如 ./mvnw spring-boot:run"
              onChange={(e) => onChange({ commandText: e.target.value })}
              spellCheck={false}
            />
            {/* directly under the input: the preview and hints below change height on toggle,
                so anything placed after them would jump away from the cursor */}
            <label className="tog" style={{ marginTop: 6 }}>
              <input type="checkbox" checked={svc.viaShell} aria-label="通过 Shell 运行" onChange={(e) => onChange({ viaShell: e.target.checked })} /> 通过 Shell 运行（{svc.shell}{' '}
              {svc.shellFlag}）
            </label>
            {cmd.error && svc.commandText ? (
              <div className="hint bad">✕ {cmd.error}</div>
            ) : cmd.argv.length > 0 ? (
              <div className="argv">
                argv: [{cmd.argv.map((a) => JSON.stringify(a)).join(', ')}]{svc.viaShell ? `（通过 ${svc.shell} ${svc.shellFlag} 运行）` : ''}
              </div>
            ) : null}
            {le('command') && !(cmd.error && svc.commandText) && <div className="hint bad">✕ {le('command')}</div>}
            {bg && <div className="hint warn">⚠ 检测到 “{bg}”：请使用前台运行方式，后台化的进程无法被管理</div>}
            {resolutionHint}
            <FieldHints issues={shownCmdIssues} />
          </div>
          <details open={svc.env.length > 0 || !!le('stopTimeoutSec')}>
            <summary>高级：环境变量 · 停止等待</summary>
            <EnvTable rows={svc.env} onChange={(env) => onChange({ env })} />
            <FieldHints
              local={Object.entries(localErrors).filter(([k]) => k.startsWith(`${localPrefix}.env`)).map(([, v]) => v).join('；') || undefined}
              issues={fieldIssues(p('env'))}
            />
            <div className="f" style={{ maxWidth: 220, marginTop: 10 }}>
              <label htmlFor={`${uid}-stop`}>正常停止等待（秒）</label>
              <input
                id={`${uid}-stop`}
                className={`in${le('stopTimeoutSec') ? ' invalid' : ''}`}
                value={svc.stopTimeoutSec}
                aria-label="正常停止等待（秒）"
                placeholder="10"
                inputMode="numeric"
                onChange={(e) => onChange({ stopTimeoutSec: e.target.value })}
              />
              <FieldHints local={le('stopTimeoutSec')} issues={fieldIssues(p('stopTimeoutSec'))} />
            </div>
          </details>
        </div>
      )}
    </div>
  );
}

function EnvTable({ rows, onChange }: { rows: EnvRow[]; onChange: (rows: EnvRow[]) => void }) {
  const set = (key: string, patch: Partial<EnvRow>) => onChange(rows.map((r) => (r.key === key ? { ...r, ...patch } : r)));
  return (
    <>
      {rows.length > 0 && (
        <table className="envt">
          <tbody>
            {rows.map((r) => (
              <tr key={r.key}>
                <td style={{ width: '38%' }}>
                  <input
                    className="in mono"
                    value={r.name}
                    placeholder="名称"
                    spellCheck={false}
                    onChange={(e) => {
                      const name = e.target.value;
                      set(r.key, r.secretTouched || r.stored ? { name } : { name, secret: SECRET_NAME.test(name) });
                    }}
                  />
                </td>
                <td>
                  {r.secret ? (
                    <input
                      className="in mono"
                      type="password"
                      autoComplete="new-password"
                      value={r.value}
                      placeholder={r.stored ? '已设置（留空则保持不变）' : '敏感值'}
                      onChange={(e) => set(r.key, { value: e.target.value })}
                    />
                  ) : (
                    <input className="in mono" value={r.value} placeholder="值" spellCheck={false} onChange={(e) => set(r.key, { value: e.target.value })} />
                  )}
                </td>
                <td className="lock">
                  <button
                    className={`locktog${r.secret ? ' on' : ''}`}
                    title={r.secret ? '敏感：值不会再显示，也不会出现在任何响应与日志中' : '标记为敏感'}
                    aria-pressed={r.secret}
                    onClick={() => set(r.key, r.secret ? { secret: false, secretTouched: true, stored: false, value: r.stored ? '' : r.value } : { secret: true, secretTouched: true })}
                  >
                    {r.secret ? '🔒' : '🔓'}
                  </button>
                </td>
                <td className="del">
                  <button className="ib" onClick={() => onChange(rows.filter((x) => x.key !== r.key))} aria-label="删除变量" title="删除变量">
                    ✕
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <button className="b sm" style={{ margin: '6px 0 4px' }} onClick={() => onChange([...rows, emptyEnvRow()])}>
        ＋ 变量
      </button>
    </>
  );
}
