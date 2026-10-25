/** Agent rule text from docs/product-design-v0.1.md §11.3, with the real project ID filled in. */
export function agentRules(projectId: string): string {
  return `本项目的长期运行服务统一由DevPanel管理。

项目ID：${projectId}

启动前先查询DevPanel状态。启动、停止、重启、查看运行日志和资源，
使用DevPanel CLI，不另用nohup、&、tmux或Agent临时后台任务启动同一服务。

DevPanel不可用时报告问题，不绕过它启动项目。
不要接管或结束不属于本项目受管运行的进程。
用户主动停止后，结束当前自动启动/重启流程，不自行循环重试。
用户明确重新要求启动时，读取最新状态后通过DevPanel发起新的请求。
修改运行配置应更新已注册项目，而不是注册一个重复项目。
`;
}

export const REGISTER_HINT = 'devpanel project register --config ./devpanel.json --json';
export const DAEMON_START = 'devpanel daemon start';
