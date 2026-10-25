你负责实现 DevPanel v0.3 的前后端（daemon、CLI、mock、macOS 原生程序）。仓库：/path/to/DevPanel，分支 `main`。macOS 27、Xcode 27.1、Swift 6.4、Node 24、pnpm 12。

按下面的阶段顺序完成，每个阶段（可再细分）自检后单独提交到本地 `main`，不推送。遇到需要用户决定或用户亲自操作的事项，记进最终汇报，不要因此卡住其他阶段。

---

## 0. 先读（全部读完再动手）
1. `AGENTS.md` —— 特别是“用户的稳定版”一条和“v0.3 分工”一节。
2. 产品：`docs/product-design-v0.3.md`（第 2 稿；v0.1 / v0.2 中未被覆盖的约定继续有效）。
3. 界面：`docs/ui-design-v3.md`（第 2 稿），视觉稿 `docs/ui-mockup-v3.html`（7 个场景，浏览器打开对照）；`docs/ui-design-v2.md` 中未被修改的规则继续有效。
4. 计划：`docs/plan-v0.3.md`（阶段、关键实现要求、测试要求）。
5. 契约：`contract/api.md` 的 §2 路由表、§9 CLI、**§11 快捷操作与 Maven**、**§12 Git**；`packages/contract/src/index.ts` 末尾的 v1.2 类型；`contract/CHANGES.md` 中 v1.2-C、v1.2-D（已生效）。契约已经写好，你不需要改；发现问题按 `AGENTS.md` 写待决提案。
6. 现有实现：`apps/mac/README.md`、`docs/backend-design.md`、`docs/plan-v0.2.md` 的结构说明。

注意：契约新增了必填字段（`ProjectView.actions` / `maven`、`ProjectStats.tasks`、`Limits.taskRunsKept` / `logBytesPerTaskRun`），所以当前 `packages/daemon`、`tools/mock-daemon`、`apps/ui` 的类型检查是失败的，这是要你补上的。`apps/ui`（旧 Web 界面）只需修到能通过类型检查和现有测试，不需要实现新功能。

## 1. 硬性规则
- **不碰用户的稳定版**：不调用 `~/.local/bin/devpanel`，不运行不带 `--bin-dir` 的 `setup:cli`，不修改 `~/.local/share/devpanel/stable` 和 `/Applications/DevPanel.app`，不停止或重启用户正在运行的 daemon（它使用真实数据目录 `~/Library/Application Support/DevPanel`）。开发、测试、验收一律用 `node packages/cli/src/main.ts` 和临时的短路径 `DEVPANEL_HOME`（例如 `.devpanel-dev/v03-xxx`，socket 路径 ≤ 103 字节）。
- **进程安全**：只对 pid + 启动时间核验属于本次运行的进程发信号；停止你自己启动的进程只按启动时记录的 PID（先核对命令行），不按名称、不按端口；测试结束不得留下孤儿进程（v0.2 曾遗留过一个 `service.mjs silent`，请顺便查出是哪个测试漏清理并修掉）。
- **Git 安全**：所有 Git 测试使用临时仓库；不对本仓库或任何用户仓库执行写操作；不删除 `index.lock`；不实现丢弃、删除储藏、分支切换、远端操作。
- **Maven 安全**：pom 只做静态解析；命令只由 daemon 从结构化参数构造并严格校验；测试不访问网络（用不依赖下载的假 `mvnw` 脚本模拟 Maven 输出与退出码）。
- **范围**：只做 v0.3 第 2 稿；不做 Dependencies 树、Plugins 节点、settings.xml、Gradle、任务编排、定时任务。
- **质量**：每次提交前 `pnpm typecheck`、`pnpm test`、`cd apps/mac && swift build && swift test` 全部通过且 0 编译警告；`apps/mac/scripts/bundle.sh` 能产出可运行的 `.app`。保持测试的 `--test-timeout` / `--test-force-exit`。
- 临时文件、截图放 `.devpanel-dev/codex/v03/`（已被 git 忽略）。

## 2. 阶段

### 阶段 A：通用任务运行 + 快捷操作（后端 → mock → 原生）
- daemon：`ActionConfig` 校验（同服务，含 `${key}` 引用与 `usedBy` 的 `action:<id>`）；通用的“任务运行”托管（复用服务的 spawn、进程组、身份核验、子进程跟踪、日志、采样；新增运行到结束的状态机、取消 / 强制取消 / `cancelTimedOut`、`timeoutSec` 超时、保留 `taskRunsKept` 次、单次日志上限）；`ProjectView.actions`、`ProjectStats.tasks`；daemon 重启核验；删除保护。路由：actions runs、`/task-runs/:runId`、cancel。CLI：`action list|run`、`task cancel`、`logs --run` 接受任务运行。
- mock：同步实现，种子数据给 order-service 加 3 个快捷操作（含一个引用选项、一个 `confirmWhenServicesRunning`、一个会失败的）。
- 原生：项目检查器（`selection` 支持“服务或项目”）、“快捷操作”标签（列表 + 选中项输出，复用日志视图与历史运行切换）、项目卡片的快捷操作行、运行前确认、编辑 sheet 的“快捷操作”分区、运行结束通知（窗口不在前台时；主动取消不通知）、菜单“运行快捷操作 ▸ / 取消运行中的任务”。

### 阶段 B：Maven 视图（后端 → mock → 原生）
- daemon：pom 静态解析（嵌套 `<modules>`、坐标与 `<parent>` 继承的 groupId、缺省 packaging、profiles、父 POM 在项目外、单个 POM 解析失败）、按修改时间缓存、`reload`；可执行文件选择（`maven.executable`）；命令构造与校验；每项目单 Maven 运行；`ProjectView.maven`。CLI：`maven modules`、`maven run`。
- mock：一个多模块假 Maven 项目（根 pom + backend + contracts + 一个父 POM 在项目外的模块 + 一个解析失败的模块），模拟 Maven 输出（Reactor、各插件段、WARNING、BUILD SUCCESS / FAILURE）。
- 原生：项目检查器“Maven”标签（仅有 pom 时出现），按 ui-design-v3 §3：工具栏（重新加载、运行、取消、跳过测试 / 离线 / -am 开关并按项目记住、运行 Maven 目标…、存为快捷操作）、模块树 + Lifecycle + Profiles 三态、单击 / ⌘ 多选 / 双击运行 / 右键菜单、命令预览行、输出区、`clean` 运行前确认、忙时提示；项目卡片快捷操作行末尾的“Maven…”与运行状态；菜单 ⌥⌘M。

### 阶段 C：Git（后端 → mock → 原生；与 A / B 无依赖，可在临时工作树并行，合并后删除）
- daemon：按 api.md §12 实现 status（porcelain v2、`-z`、分组、截断、ahead / behind、`sensitiveName`）、diff（`staged`、`context=N|all`、未跟踪、二进制与大小、截断）、stage / unstage、commit（`expectedHead`、钩子输出、锁、HEAD 移动）、stashes / stash / stash apply（冲突保留储藏）；写操作只接受 `ui` 客户端；路径越界拒绝；git 不存在 / 非仓库。
- mock：内存中的假仓库，覆盖所有分组、一个敏感文件、一个二进制文件、两个储藏，并能模拟钩子失败与锁冲突。
- 原生：项目卡片 Git 摘要；项目检查器“Git”标签（**列表优先**，ui-design-v3 §5.1：分支行、分组列表、多选批量暂存、`+N −M`、敏感标记、储藏列表、提交区）；**差异窗口**（独立 NSWindow，§5.2：并排 / 统一、整文件上下文与未改动段折叠、行内变化高亮、上 / 下一个改动与文件、暂存此文件、文件变化提示、同一文件不重复开窗）；敏感文件提交前警告；钩子失败横幅与输出；HEAD 移动、锁冲突、储藏冲突提示；刷新策略（§5.4：仅可见且窗口在前台时每 5 秒，写操作后立即）；快捷键（Space、Enter、⌘↩、F7 / ⇧F7、⌘] / ⌘[、⌥⌘G）。

### 阶段 D：联调、验收与文档
1. 用临时 `DEVPANEL_HOME` 启动真实 daemon，组装验收项目：一个真实多模块 Maven 项目的**副本**（可从 `/Users/demo/Projects/cosmetic` 复制 pom 结构到临时目录，不要在原目录运行任何东西）、一个临时 Git 仓库。逐条验证 `docs/product-design-v0.3.md` §5，并用 `--snapshot` 截图。
2. 资源复测：DevPanel 自身在 Git 页可见 / 不可见、Maven 运行中 / 结束后的 CPU 与内存，确认不可见时零轮询、任务结束后采样释放；写进 `docs/plan-v0.3.md`。
3. 更新 `docs/plan-v0.3.md`（每项状态、验收结果、截图索引、需要用户手动验证的交互清单）、`apps/mac/README.md`、`docs/backend-design.md`。
4. 不升级用户的稳定版。在汇报里给出“把稳定版升级到 v0.3”的步骤建议（打标签 `v0.3.0` 之后由用户执行），步骤见 `docs/plan-v0.3.md` 末尾。

## 3. 最终汇报
1. 每个阶段的提交列表与完成情况。
2. 主要新增 / 修改的文件与结构。
3. 测试结果（Swift 与 pnpm 的数量、耗时），以及孤儿进程问题的结论。
4. 截图清单（绝对路径 + 一句说明）与视觉稿差异。
5. §5 逐条验收结果；资源复测数据。
6. 需要用户亲自操作或决定的事项（手动交互清单、契约提案、升级稳定版）。
7. 已知限制。
