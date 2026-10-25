你是 DevPanel 项目的后端开发者。仓库：/path/to/DevPanel（pnpm workspace，Node 24，macOS 优先）。前端由另一个 Agent（Claude）在同一仓库里并行开发，你们之间唯一的对接点是接口契约。

## 先读（按顺序，全部读完再动手）
1. `AGENTS.md`：目录所有权、契约变更流程、安全底线。你只能修改 `packages/daemon/`、`packages/cli/`、`docs/backend-design.md`，以及在根 `package.json` 里追加脚本。
2. `docs/product-design-v0.1.md`：产品范围。重点是 §4、§7–§13、§16。
3. `contract/api.md` + `packages/contract/src/index.ts`：你要实现的接口。路由、字段、状态、错误码、退出码以它们为准。
4. `docs/ui-design.md`：了解 UI 会怎样使用你的接口（只读，不要改）。

## 要交付什么
- `packages/daemon`：管理服务 `devpaneld`。它是唯一能创建和控制受管进程的入口，同时负责配置持久化、日志采集、资源采样、操作队列、SSE 事件流、静态 UI 托管（目录取 `DEVPANEL_UI_DIR`，默认 `apps/ui/dist`；目录不存在时返回一个简单的占位页）。
- `packages/cli`：命令行 `devpanel`，按契约 §9 实现。它只是客户端，通过 Unix socket 调用 daemon，自己不执行项目命令。
- `docs/backend-design.md`：工程设计说明（下面列的决策都要写进去），以及实测记录。
- 依赖 `@devpanel/contract`（workspace 包）中的类型，不要另抄一份。

## 必须由你做出并写明的工程决策
1. **进程托管**：以前台方式启动，每个运行使用独立的会话 / 进程组。用“进程组 + 定期按 ppid 发现的后代进程”跟踪进程范围；对每个被跟踪的进程记录 pid + 启动时间作为身份，已发现的后代即使离开进程组或被重新挂到 1 号进程下也继续跟踪。停止时只对身份核验通过的进程发信号。
2. **日志采集方式**，同时满足以下约束：(a) 永远不阻塞业务进程的输出；(b) 磁盘和内存都有上限（契约 §6.2）；(c) daemon 崩溃或重启时，受管进程不能因为 SIGPIPE 等原因被连带杀死，或者你要明确写出它会发生、以及发生后 UI 和 CLI 会看到什么；(d) daemon 重启后能接续的就接续，接续不了就如实标记为 `unknown` 或 `gap`。可选方案示例：把 stdio 重定向到每个运行的日志文件，由 daemon 增量读取并加上 seq；或者用管道。写清你的选择、理由和缺口。
3. **资源采样**：macOS 上没有 psutil。可以考虑每 2 秒执行一次 `ps -axo pid=,ppid=,pgid=,rss=,time=,lstart=` 并用累计 CPU 时间的差值算 CPU%（不要直接用 `ps %cpu`，macOS 上那是衰减平均值），也可以用别的手段，但不要引入重量级依赖。只在有运行中服务时采样，多个客户端共享同一份结果。
4. **daemon 生命周期**：`devpanel daemon start` 以脱离终端的方式启动 daemon，CLI 退出、终端关闭都不影响它；建议额外提供 `devpanel daemon install`，安装一个 launchd LaunchAgent（只拉起 daemon 本身，绝不自动启动业务项目）。单实例：用锁文件或 socket 探测，防止起两个 daemon。
5. **持久化**：JSON 文件 + 原子写（先写临时文件再 rename），放在 `DEVPANEL_HOME` 下，权限 0700 / 0600。不要用数据库服务。
6. **执行环境**：基础 PATH 从哪里来（例如 `daemon install` 时从用户登录 shell 抓取一次，并保存在 daemon 配置里），如何保证 UI 和 CLI 发起的启动用的是同一套环境。

## 硬性要求（违反即视为未完成）
- 注册、更新、校验都不执行项目命令。保存配置不会触发启动或重启。
- 同一个服务在任何并发情况下（UI 和 CLI 同时启动、连续点击）最多只有一个受管实例。
- 停止会取消该服务上未完成的启动和重启，被取消的请求事后不能把服务再拉起来。重启必须等旧进程确认退出后再启动新进程。
- 停止超时后服务保持 `stopping` 且 `stopTimedOut=true`，绝不报告成已停止；提供 `force-stop`。
- 资源统计必须包含真正干活的子进程（例如 `mvn` 拉起的 java、`pnpm` 拉起的 node）；拿不到的数据用 `sampling` / `partial` / `unavailable` 表示，绝不填 0。
- HTTP 只绑定 127.0.0.1，并实现契约 §1.1 的全部校验（token / Cookie、Host、Origin、`X-DevPanel-Client`、一次性 code 换 Cookie）。
- 敏感环境变量值不出现在任何响应、事件、`sys` 日志行和 CLI 输出里。
- 所有测试和开发运行都用临时的 `DEVPANEL_HOME`，不触碰真实数据目录，不注册真实项目。
- 不做产品文档 §14 列出的任何功能。

## 测试
- 在 `packages/daemon/test/fixtures/` 下用小型 Node 脚本模拟各种被管服务：持续输出的普通服务、会 fork 子进程（含 detach 出去的孙进程）的服务、忽略 SIGTERM 的服务、启动后立刻退出（code 0 和 1）的服务、大量输出（触发截断）的服务、只输出到 stderr 的服务、输出 ANSI 颜色的服务、输出超长单行的服务。
- 用 `node:test`（或同等轻量的方案）写集成测试，启动真实 daemon（临时 HOME、随机端口），通过 HTTP 和 CLI 两条路径覆盖产品文档 §16 的验收表格，逐条对应。特别要覆盖：并发启动只产生一个实例、在重启过程中停止、停止超时后强制停止、子进程被计入且停止后无残留、daemon 重启后的核验、外部请求（错误的 Origin / Host / 无 token）被拒绝。
- 根目录 `pnpm typecheck` 和 `pnpm test` 必须通过。

## 契约问题
如果契约有遗漏、矛盾或无法实现之处，按 `AGENTS.md` 在 `contract/CHANGES.md` 写提案，在提案确认之前按现有契约实现，并在最终汇报里列出。不要直接修改 `contract/` 或 `packages/contract/`。

## 完成后的汇报（发给用户，用户会转给前端 Agent）
1. 修改了哪些文件和模块，并给出 `docs/backend-design.md` 的要点摘要。
2. 如何启动：安装、`devpanel daemon start`、`devpanel open`，开发模式怎么用临时 HOME 跑。
3. CLI 用法示例（真实可运行）。
4. §16 验收表逐条的实测结果（通过 / 未通过 / 未测，附命令和关键输出）。
5. daemon 自身的空闲 CPU / 内存实测值（不含受管进程）。
6. 契约变更提案列表（如有）和剩余限制。
