import { useEffect } from 'react';
import { ConfigDrawer } from './components/ConfigDrawer';
import { Dialogs } from './components/Dialogs';
import { Sidebar } from './components/Sidebar';
import { Workspace } from './components/Workspace';
import { Spinner } from './components/common';
import { DAEMON_START, REGISTER_HINT } from './lib/rules';
import { copyText, moveSelection, openDrawer, reconnectNow, selectedProject, startEvents, useApp } from './store/app';

function isTyping(el: EventTarget | null): boolean {
  if (!(el instanceof HTMLElement)) return false;
  return el.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName);
}

export function App() {
  const project = useApp(selectedProject);
  const hasProjects = useApp((s) => s.projects.length > 0);
  const conn = useApp((s) => s.conn);
  const drawer = useApp((s) => s.drawer);
  const overlay = useApp((s) => s.drawer !== null || s.dialog !== null);
  const toasts = useApp((s) => s.toasts);

  useEffect(() => {
    startEvents();
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f' && !overlay) {
        e.preventDefault();
        window.dispatchEvent(new Event('devpanel:find'));
        return;
      }
      if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && !overlay && !e.metaKey && !e.altKey && !isTyping(e.target)) {
        const t = e.target as HTMLElement | null;
        // let the log view and list handle their own arrows when focused
        if (t && (t.closest('.lbody') || t.closest('.plist') || t.closest('.menu'))) return;
        e.preventDefault();
        moveSelection(e.key === 'ArrowDown' ? 1 : -1);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [overlay]);

  let main: React.ReactNode;
  // A daemon restart drops browser sessions, so 401 can also arrive after we were connected;
  // retrying cannot fix it, only a new login code can.
  const unauthorized = conn.status !== 'connected' && conn.error?.code === 'UNAUTHORIZED';
  if (unauthorized || !conn.everConnected) {
    if (unauthorized) {
      main = (
        <main className="main">
          <div className="empty">
            <div className="box">
              <h2>未登录管理服务</h2>
              <p>页面需要一次性登录码才能访问数据。请在终端运行下面的命令重新打开面板：</p>
              <pre>devpanel open</pre>
              <button className="b" onClick={() => void copyText('devpanel open')}>
                复制命令
              </button>
            </div>
          </div>
        </main>
      );
    } else if (conn.status === 'disconnected') {
      main = (
        <main className="main">
          <div className="empty">
            <div className="box">
              <h2>无法连接 DevPanel 管理服务</h2>
              <p>管理服务可能尚未启动。请在终端运行：</p>
              <pre>{DAEMON_START}</pre>
              <button className="b" onClick={() => void copyText(DAEMON_START)}>
                复制命令
              </button>{' '}
              <button className="b" onClick={reconnectNow}>
                立即重试
              </button>
              <p className="hint">{conn.error?.message ? `原因：${conn.error.message} · ` : ''}会自动重试连接；连上之前不显示任何项目状态。</p>
            </div>
          </div>
        </main>
      );
    } else {
      main = (
        <main className="main">
          <div className="empty">
            <div className="box">
              <Spinner /> 正在连接管理服务…
            </div>
          </div>
        </main>
      );
    }
  } else if (!hasProjects) {
    main = (
      <main className="main">
        <div className="empty">
          <div className="box">
            <h2>还没有项目</h2>
            <p>在你的编程 Agent 里说「把当前项目加入 DevPanel」，它会读取项目的真实启动方式并注册；也可以手动添加。</p>
            <pre>{REGISTER_HINT}</pre>
            <button className="b primary" onClick={() => openDrawer({ mode: 'create' })}>
              ＋ 添加项目
            </button>{' '}
            <button className="b" onClick={() => void copyText(REGISTER_HINT)}>
              复制命令
            </button>
          </div>
        </div>
      </main>
    );
  } else if (project) {
    main = <Workspace project={project} />;
  } else {
    main = (
      <main className="main">
        <div className="empty">
          <div className="box">在左侧选择一个项目。</div>
        </div>
      </main>
    );
  }

  return (
    <div className="window">
      <Sidebar />
      {main}
      {drawer && <ConfigDrawer key={drawer.mode === 'edit' ? drawer.projectId : 'create'} state={drawer} />}
      <Dialogs />
      <div className="toasts" aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={`toast${t.tone === 'bad' ? ' bad' : ''}`}>
            {t.text}
          </div>
        ))}
      </div>
    </div>
  );
}
