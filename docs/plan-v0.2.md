# v0.2 开发计划

> 范围：[product-design-v0.2.md](product-design-v0.2.md)。界面：[ui-design-v2.md](ui-design-v2.md)。契约：`contract/CHANGES.md` 中的 v1.1-A（选项）、v1.1-B（端口）。
> 2026-10-20 收尾：按 `AGENTS.md` 最后一节，A（F4）、B（F6）、C（联调）、D（文档）由 Codex 完成。原有 F0–F3 / F5 保留；本次未启动子代理。系统交互待用户人工验收，Web 退役待决定。

## 顺序与依赖

```
阶段 0  文档 + 契约提案 ──▶ 用户确认
                           │
阶段 1  Claude：把已接受的提案写入 contract/api.md 与 packages/contract（提出方负责）
                           │
          ┌────────────────┼──────────────────────────┐
阶段 2  后端 B1–B3（Codex）  前端 F0 mock-daemon      前端 F1 原生程序地基
          │                 │                           │
          │                 └──────────┬────────────────┘
          │                            ▼
          │                 前端 F2 总览 ─▶ F3 检查器 / F4 选项 / F5 项目编辑（可并行，文件互不重叠）
          │                            ▼
          │                 前端 F6 程序级行为（关窗、退出、通知、菜单）
          ▼                            ▼
阶段 3  联调：原生程序接真实 daemon，按 v0.2 §7 + v0.1 §16 验收（已用真实 daemon + 隔离 fixture 验证；个人项目由用户验收）
阶段 4  决定 Web 界面（apps/ui）是否退役、daemon 是否停止托管页面
```

## 后端（Codex）

| 编号 | 内容 | 完成标准 |
| --- | --- | --- |
| B1 ✓ | 选项：校验、存储、启动时替换与 shell 转义、运行快照、设置者与覆盖保护 | 集成测试覆盖：占位符替换、未知 key、类型 / 范围、shell 转义、覆盖保护与 `keptUserValues`、`configChangedSinceStart` 只标记引用方 |
| B2 ✓ | 选项路由与 CLI：`POST/PATCH/DELETE /projects/:id/params`、`devpanel param list/set/remove`、Agent 规则补充 | 删除写回（含 secret 限制）、revision 冲突、设置者按客户端头区分 |
| B3 ✓ | 真实端口：在资源采样中读取受管进程的 LISTEN 套接字 | 测试服务监听 127.0.0.1 与 0.0.0.0 两种情况；非受管进程的端口不出现；停止后清空 |

提示词：[prompts/codex-backend-v0.2.md](../prompts/codex-backend-v0.2.md)（B1–B3 已完成）。

## 原生前端与 mock（原阶段 Claude；本次收尾 Codex）

| 编号 | 内容 | 主要文件 | 完成标准 |
| --- | --- | --- | --- |
| F0 ✓ | mock-daemon 实现 v1.1-A / B（选项、路由、端口），种子数据加入选项 | `tools/mock-daemon` | 现有测试 + 新增测试通过 |
| F1 ✓ | 原生程序地基：Swift Package、`DevPanelKit`（契约 Codable 类型、DaemonClient、SSE、`AppModel`）、`daemon.json` 发现、连接 / 断连 / 未运行状态、打包脚本 | `apps/mac/Package.swift`、`Sources/DevPanelKit/**`、`scripts/bundle.sh` | 用 mock-daemon 录制的 JSON 做解码测试；`.app` 能启动并连上 mock |
| F2 ✓ | 总览：工具栏、项目卡片、服务表、紧凑模式、启停与操作结果、停止超时与强制停止、端口胶囊 | `Sources/DevPanel/Overview/**` | 对照视觉稿 v2 截图 |
| F3 ✓ | 检查器：日志（NSTextView）、运行记录、命令与环境 | `Sources/DevPanel/Inspector/**`、`Sources/DevPanelKit/Logs/**` | 10 万行日志流畅；v1 日志规则全部满足 |
| F4 ✓ | 选项：标签、编辑弹窗、选项列表、新增、删除写回 | `Sources/DevPanel/Options/**` | 设置者显示、下次启动生效提示、冲突处理 |
| F5 ✓ | 项目添加 / 编辑 sheet、校验、原生目录选择 | `Sources/DevPanel/Editor/**` | 修正 v1 已知问题（点击区域、跳位、标题关联） |
| F6 ✓ | 程序级行为：首次关窗提示、⌘Q、停止所有服务并退出、通知、Dock 角标、菜单与快捷键 | `Sources/DevPanel/App/**` | v0.2 §7 对应条目 |

✓ 表示实现已完成；需要真实系统交互的验收状态以下文矩阵为准。Swift Testing 跑纯逻辑；界面运行 `.app` 并用自身快照渲染对照视觉稿，不依赖 Xcode 预览，也不把快照驱动等同于人工鼠标验收。

## 风险

- **Swift 类型与契约漂移**：Swift 端是第二份类型定义。F1 用 mock-daemon 真实响应做解码测试，契约每次变更都要同步更新这些样本。
- **大日志性能**：SwiftUI 列表不适合 10 万行；F3 直接使用 TextKit 2，并保留 v1 的内存上限。
- **验证成本**：原生界面无法用浏览器工具检查，截图走查比 Web 慢；F2–F6 每个都要求附截图。
- **两套前端并存**：阶段 4 之前 Web 界面仍在，契约变更时两边都要跟进；尽早决定退役。

## C：真实 daemon 联调记录（2026-10-20）

`apps/mac/scripts/acceptance.py` 使用独立的 `.devpanel-dev/codex/acc`（socket 路径 77 字节）、临时 CLI shim 和 daemon 测试 fixtures。通过 release `.app` 的 snapshot / app-smoke 入口驱动生产 AppModel 与窗口；没有连接用户真实 daemon、注册个人项目、安装 LaunchAgent 或复制到 `/Applications`。

已通过：CLI 注册不执行、重复注册幂等；CLI 启动与原生程序共享 runId、日志、资源和 LISTEN 端口；原生停止后 CLI 无 currentRun、端口清空、记录的 PID + 启动时间均消失；派生子孙进程跟踪；并发启动幂等；选项改值不重启、AI 更新保护人改值、重启应用新值、删除写回后可启动；停止超时、关闭 daemon 失败保留管理服务、强制停止；重启中停止取消旧操作且不产生替代运行；非零退出保留日志与角标；断连冻结旧状态；移除登记保留源文件。

真实 scene 检查通过首次关窗提示、关闭后连接保留、重开后 runId 不变、退出界面后服务继续运行。菜单通过刷新实际 NSMenu 后检查标题、快捷键和选中/未选中的 enabled 状态。通知过滤与去重有纯逻辑测试，点击处理器有截图；**系统通知授权、实际横幅和通知中心点击仍需用户亲自确认**，不能把处理器截图视为系统投递成功。

联调修正了两处边界：daemon 消失时保留灰色过期总览和启动入口；revision 冲突重试仅保留用户确实编辑过的字段，避免覆盖外部更新的名称。证据保存在 `.devpanel-dev/codex/c-results.json`、`c-cli.log`、`c-app-smoke.txt` 与 `c-*.png`。

### Release 资源实测

macOS 27 / Xcode 27.1，真实 SwiftUI 主窗口，总览停留，无日志搜索操作。预热 7 秒，再用 `ps time,rss` 每 4 秒采一次，共 5 次；CPU 为首末 CPU 时间差 / 约 16 秒墙钟时间（单核 100%），RSS 为五次均值。服务进程资源不计入 App / daemon。短时单次样本用于记录本机基线，不是性能上限。

| 情况 | App CPU | App RSS | daemon CPU | daemon RSS |
| --- | --- | --- | --- | --- |
| 无项目运行（空总览） | 0.249% | 97.93 MiB | 0.124% | 63.87 MiB |
| 3 个服务运行（监听、派生进程树、等待触发异常退出） | 1.307% | 113.24 MiB | 2.613% | 112.42 MiB |

原始采样：`.devpanel-dev/codex/c-resource-idle-samples.json`、`c-resource-three-services-samples.json`；采用带 `real window` 的结果，早期隐藏 snapshot 窗口采样仅保留为过程证据。资源复测用了独立 `perf` 目录，受管进程身份核验无残留。

## 收尾交付状态

| 任务 | 状态 | 本地 main 提交 / 说明 |
| --- | --- | --- |
| A · F4 | 完成 | `2e0851c`：四种控件、secret、自动保存、增删写回、冲突、实际运行值比较 |
| B · F6 | 完成；系统交互需人工验收 | `9e3932e`：窗口生命周期、菜单、通知、Dock、定位和跟随收尾 |
| C · 联调 | 自动化链路通过；通知投递需人工验收 | `ceefd0d`：可重复的真实 daemon 验收脚本、边界修复、资源实测 |
| D · 文档 | 完成 | 本文件及 `apps/mac/README.md`；提交主题 `docs: finish v0.2 acceptance and native app usage guide` |

没有修改接口契约，没有新增待决契约提案。没有实现 v0.3 任务 / Git，没有移除 Web。所有提交留在本地 main，不推送。

### 主要结构

- `apps/mac/Sources/DevPanelKit/Options/{OptionRules,OptionEditor}.swift`：纯逻辑校验、显示与写回预览、自动保存、冲突重试。`State/AppModel+Options.swift` 统一 CRUD。
- `apps/mac/Sources/DevPanel/Options/`：popover 与检查器共用输入控件；添加 / 删除 sheet 和快照入口。`Presentation/ParamChips.swift` 比较 RunDetail 中的实际选项值。
- `apps/mac/Sources/DevPanel/App/`：AppController、AppCommands、AppNotifications、WindowBridge、AppSnapshot、AppSmoke。`DevPanelKit/State/AppBehavior.swift` 保存通知筛选 / 去重和角标逻辑。
- `apps/mac/scripts/acceptance.py`：fixture 注册、CLI 与 App 双向操作、身份核验、两种主窗口资源采样；`Tests/DevPanelKitTests/{OptionTests,AppBehaviorTests}.swift` 补充回归。
- `RootView.swift` / `AppModel+Inspector.swift`：断连后冻结旧总览；既有 Editor / Inspector / Overview 接线更新。

### v0.2 §7 逐条结果

| 场景 | 结果 | 证据 |
| --- | --- | --- |
| AI 注册含选项项目 | 通过：没有执行，名称/说明/choices/占位符保留 | `c-registered-options.png`、`c-cli.log` |
| 人改选项值 | 通过：runId 不变、待生效；重启后实际命令为新 host | `c-option-pending.png`、`c-option-restarted.png` |
| AI 再次更新 | 通过：`keptUserValues: ["host"]`，保留 `0.0.0.0` | `c-results.json` |
| 删除被引用选项 | 通过：命令写回 `0.0.0.0`，再次启动成功 | `c-delete-inline.png`、`c-inline-starts.png` |
| 真实监听端口 | 通过：由真实 LISTEN 获取地址/端口，停止后清空 | `c-cli-start-native-logs.png`、`c-ui-stop-cli-confirm.png` |
| 关窗 / 退出 | 自动化通过：实际 NSWindow 关闭/重开、退出后同一运行；Dock 点击与 ⌘Q 人工补验 | `c-app-smoke.txt`、`c-cli.log` |
| 自行异常退出 | 状态/日志/角标、通知筛选去重及点击路由通过；**系统授权/横幅/点击待用户确认** | `c-self-exit.png`、`c-notification-route.png`、AppBehaviorTests |
| daemon 未运行 | 通过：提示、通过临时 CLI shim 启动，仅启动 daemon | `c-daemon-not-running.png`、`c-launch-daemon.png` |

### v0.1 §16 相关回归

| 场景 | 本次验证 |
| --- | --- |
| 注册 / 重复注册 | 真实 CLI 幂等且无隐式执行 |
| UI 启动 → CLI 查询 | snapshot 调生产 AppModel；CLI 得到同一 runId |
| CLI 启动 → UI 查看与停止 | 真实 runId / 日志 / RSS / LISTEN 一致；UI 停止、CLI currentRun=null、身份消失 |
| UI / CLI 并发启动 | 同一受管实例，started 或 already-running 指向同一 runId |
| 多服务 / 子进程 | 三个服务分别操作；tree 的根、子、分离孙进程均被跟踪和清理；合计口径由回归测试覆盖 |
| 命令或目录错误 | 既有 daemon 与 Swift 错误映射回归通过；本轮未新增真实窗口错误场景 |
| 程序自行退出 | failed / 退出信息、结束后日志与角标可见 |
| 停止超时 / 强制停止 | 超时仍 stopping，关闭 daemon 失败如实显示；force-stop 后三层进程身份消失 |
| 重启中停止 | 旧 restart 为 cancelled，runId 未更换，随后清理旧进程 |
| 关窗 / 退出 / 重开 | 实际 scene 与 CLI 检查同一 runId；用户 Dock / 键盘操作待验 |
| 重启 / 旧日志 | 新运行与历史运行分开；LogSession 代次、runId、历史跟随禁用测试通过 |
| 大日志 / 缺失资源 | 既有日志上限、分页、切换与缺失值测试通过；本轮未重复 10 万行交互性能测量，滚轮/搜索人工补验 |
| 管理连接中断 | 真实 daemon 停止后总览灰化、计时冻结，显示过期与启动入口 |
| 非受管同名进程 / API 边界 | 既有 daemon 身份与请求安全回归通过，本轮无按名称/端口发信号 |
| 移除项目 | 原生确认删除登记后列表为空；fixture `keep-me.txt` 仍存在 |

### 关键命令与输出摘录

完整可重复步骤见 `apps/mac/scripts/acceptance.py`，完整输出在 `.devpanel-dev/codex/c-cli.log`。以下 ID / 端口只是本次证据，不能用于未来发信号。

```text
devpanel project register --config <isolated-config> --json
  project.id = p_n4pbr67uek；所有 currentRun = null；重复注册 created = false
devpanel start p_n4pbr67uek --json
  listen runId = r_01M5CVP29RENXVVFE30R67Y3BZ
DevPanel --snapshot ... --select p_n4pbr67uek/listen --tab logs
  同一 runId；logLines = 2；rssBytes = 47300608
  LISTEN = 127.0.0.1:64432；pid = 38623；scope = loopback
devpanel project update ... --if-revision <revision> --json
  keptUserValues = ["host"]；host = 0.0.0.0
DevPanel --snapshot ... --perform stop:p_n4pbr67uek/listen
devpanel status p_n4pbr67uek --json
  state = stopped；currentRun = null；stats 中无 listen
  ps 对比已记录 pid / lstart / command：remaining = []
devpanel operation op_01M5CVRE1P6Y9Y0M3JBWHYY8HE --json
  state = cancelled；旧运行未被重新拉起
```

第一轮脚本把 `devpanel operation` 的查询成功退出码误当成被查询操作的取消退出码，导致测试中断；修正预期后完整重跑通过。保留 `c-first-attempt.log`，没有把失败轮当成通过。后续资源复测改为真实可见主窗口，数值以上表为准。

### 每次提交前的检查

所有检查均显式设置隔离 `DEVPANEL_HOME`。A / B / C / D 均执行 Swift build/test、根目录 pnpm typecheck/test 和 release bundle；无 Swift 编译警告。

| 提交阶段 | Swift Testing | pnpm test | 其他 |
| --- | --- | --- | --- |
| A | 213 / 32 suites，1.194s | 132，通过；daemon 34.27s、CLI 1.98s、mock 8.39s、UI 0.087s | typecheck / bundle 通过 |
| B | 217 / 33 suites，1.192s | 132，通过；daemon 34.43s、CLI 2.05s、mock 8.76s、UI 0.167s | typecheck / bundle / app-smoke 通过 |
| C | 218 / 33 suites，1.187s | 132，通过；daemon 34.30s、CLI 1.73s、mock 7.87s、UI 0.112s | typecheck / bundle / self-check 通过 |
| D | 218 / 33 suites，1.182s | 最终 132 通过；daemon 34.61s、CLI 2.03s、mock 8.31s、UI 0.093s | typecheck / bundle / self-check / 链接 / diff 通过 |

pnpm 132 = daemon 39 + CLI 16 + mock 25 + Web UI 52。包测试会并行，耗时不能相加作为全仓墙钟时间。Swift 行为测试耗时不含编译。完整输出为 `.devpanel-dev/codex/{a,b,c,d}-{build,swift-test,typecheck,pnpm-test,bundle}.log`。

D 的第一次 pnpm 回归有一项既有真实 LISTEN 测试失败：启动操作为 `partial` 而非 `succeeded`（`integration.test.ts:1403`）。原始输出保留为 `d-first-failed-pnpm-test.log`。随后用 `node --test --test-name-pattern='v0.2 real LISTEN' packages/daemon/test/integration.test.ts` 在隔离 home 单独复跑 10 次全部通过（`d-listen-repro-*.log`）；未能复现，尚不能确定根因，没有放宽断言、增加重试或修改后端。最终完整复核结果如下。此间歇性测试失败需要后续观察，不能称为已修复。

最终复核：Swift build + test + release bundle 合计墙钟 14.87s；pnpm typecheck + test 合计 38.10s（`d-*-wall.log`）。Swift 编译 0 warning；打包后 `.app --self-check` 与隔离 mock 的 REST / snapshot 一致。C 记录 50 个断言均通过（包括截图驱动和资源采样），不包含系统通知人工验收。

### 截图索引

以下链接指向本机保留的忽略目录，未提交二进制截图。颜色/间距/字号沿用 v2 Theme，对照 `ui-mockup-v2.html` 走查。snapshot 的弹窗以居中内联方式展示，真实 app 是锚定 popover / 原生 sheet；系统模糊、hover 和菜单不在 PNG 中。系统菜单用实际 NSMenu dump 替代截图，Dock 用计数测试和 `b-app-smoke.txt` 的 `badge=1 dock=1` 证明，仍需真实点击确认。

- [a-enum-dark.png](../.devpanel-dev/codex/a-enum-dark.png)：单选弹窗深色。
- [a-enum-light.png](../.devpanel-dev/codex/a-enum-light.png)：单选弹窗浅色。
- [a-number-error.png](../.devpanel-dev/codex/a-number-error.png)：数字越界，控件下方错误。
- [a-secret.png](../.devpanel-dev/codex/a-secret.png)：敏感值仅设置新值。
- [a-inspector.png](../.devpanel-dev/codex/a-inspector.png)：检查器选项、说明和引用。
- [a-add.png](../.devpanel-dev/codex/a-add.png)：添加选项表单。
- [a-delete-inline.png](../.devpanel-dev/codex/a-delete-inline.png)：删除并写回预览。
- [a-secret-blocked.png](../.devpanel-dev/codex/a-secret-blocked.png)：secret 拒绝命令写回。
- [a-conflict.png](../.devpanel-dev/codex/a-conflict.png)：revision 冲突保留输入。
- [a-pending.png](../.devpanel-dev/codex/a-pending.png)：改值后待生效。
- [a-restarted.png](../.devpanel-dev/codex/a-restarted.png)：重启后待生效消失。
- [b-first-close.png](../.devpanel-dev/codex/b-first-close.png)：首次关窗提示。
- [b-shutdown-confirm.png](../.devpanel-dev/codex/b-shutdown-confirm.png)：停止全部并退出确认。
- [b-notification-route.png](../.devpanel-dev/codex/b-notification-route.png)：通知点击处理器打开日志。
- [c-daemon-not-running.png](../.devpanel-dev/codex/c-daemon-not-running.png)：真实 daemon 未运行。
- [c-launch-daemon.png](../.devpanel-dev/codex/c-launch-daemon.png)：仅启动 daemon 的空总览。
- [c-registered-options.png](../.devpanel-dev/codex/c-registered-options.png)：CLI 注册的选项。
- [c-cli-start-native-logs.png](../.devpanel-dev/codex/c-cli-start-native-logs.png)：同一运行的日志、端口与资源。
- [c-option-pending.png](../.devpanel-dev/codex/c-option-pending.png)：真实改值待生效。
- [c-option-restarted.png](../.devpanel-dev/codex/c-option-restarted.png)：新运行的实际选项与命令。
- [c-delete-inline.png](../.devpanel-dev/codex/c-delete-inline.png)：真实删除写回预览。
- [c-deleted-inline.png](../.devpanel-dev/codex/c-deleted-inline.png)：删除完成。
- [c-inline-starts.png](../.devpanel-dev/codex/c-inline-starts.png)：写回后再次启动。
- [c-ui-stop-cli-confirm.png](../.devpanel-dev/codex/c-ui-stop-cli-confirm.png)：原生停止、CLI 确认。
- [c-ui-start.png](../.devpanel-dev/codex/c-ui-start.png)：原生启动与 CLI 并发请求。
- [c-stop-timeout.png](../.devpanel-dev/codex/c-stop-timeout.png)：停止超时与强制入口。
- [c-shutdown-failure.png](../.devpanel-dev/codex/c-shutdown-failure.png)：停止失败保留 daemon 并显示原因。
- [c-force-stop.png](../.devpanel-dev/codex/c-force-stop.png)：强制停止后状态。
- [c-stop-during-restart.png](../.devpanel-dev/codex/c-stop-during-restart.png)：重启中停止取消旧操作。
- [c-self-exit.png](../.devpanel-dev/codex/c-self-exit.png)：非零退出、保留日志。
- [c-notification-route.png](../.devpanel-dev/codex/c-notification-route.png)：真实服务通知路由结果（非系统投递）。
- [c-disconnected.png](../.devpanel-dev/codex/c-disconnected.png)：断连后灰化旧状态。
- [c-remove-project.png](../.devpanel-dev/codex/c-remove-project.png)：移除登记确认。
- [c-removed-project.png](../.devpanel-dev/codex/c-removed-project.png)：移除后空总览。

### 用户人工验收与待决定事项

1. **窗口 / 菜单**：首次关窗提示、下次普通启动不再提示；关闭后 Dock 点击重开、⌘Q 后服务继续；⌘N、⌘↩（连续按）、⌘R、⌘L、⌥⌘I、⌘F 的实际响应和禁用状态。
2. **日志 / 焦点**：⌘F 的总览/日志分流、Enter / ⇧Enter 搜索跳转、双击服务行、滚轮停止跟随、历史运行 Follow 禁用、悬停时间戳及失败完整文案。
3. **表单**：真实 popover 失焦/500ms 自动保存；名称与说明编辑；原生 sheet、NSOpenPanel 选择目录；添加、删除写回、冲突重试及错误保留输入。
4. **系统通知**：使用 `.app`，保持窗口已连接后触发非零退出，允许权限并看到横幅；点击应重开窗口并定位日志；用户主动停止和 exit(0) 不通知；同一运行不重复；确认 Dock 数字与实际 failed/unknown 数一致。此前 snapshot 仅验证处理器，启动首 snapshot 不补历史通知。
5. **个人项目**：按 README 安装 CLI → 启动 daemon → 打包/打开。选择一个用户认可的非关键项目，CLI 注册但不启动，再 CLI 启动；在 app 对照 runId、日志、真实端口，改选项后重启，再由界面停止、CLI 确认。用自己的典型日志量补验滚动与搜索；本次没有注册任何个人项目。
6. **Web 去留**：建议人工验收通过前保留 `apps/ui` 与托管路由，之后另开退役任务。两套客户端持续增加契约字段/枚举/回归维护成本。停止托管页面会改变 `contract/api.md` §1.1.6 的静态页面承诺，应先提契约变更并同步语义/类型（如涉及类型）；当前没有擅自提交这项提案或删除代码。是否退役、何时停止托管由用户决定。
7. **安装方式**：是否使用 `daemon install` 登录自启、是否复制到 `/Applications` 由用户选择。本次只测试临时 shim；仓库 CLI 回归中的 launchd 测试使用隔离 job 并清理，不安装真实用户服务。

### 已知限制与 v0.3 起点

- 契约只有值修改时间 `valueUpdatedAt`，没有独立的说明修改时间；仅修改说明时显示“说明由你编辑”，不编造时间。没有新增契约字段。
- secret 的保存值和运行值都被遮盖，无法精确比较；使用配置变化/时间回退。run detail 拉取失败也回退；普通可见值按运行快照比较。
- 系统通知可被权限/专注模式/系统设置抑制，真实投递没有自动确认；ad-hoc 签名用于本机运行，未做发行公证。
- 资源实测是短时、单机、三服务 fixture 样本；未宣称长期负载或 10 万行交互性能达标。进程身份仍受 ps 启动时间精度与信号前竞态限制，沿用后端边界。
- 既有真实 LISTEN 间歇失败后续已定位测试端口预留缺陷，见本文件“LISTEN 测试收尾”；原始那次缺少服务日志，不能追溯定论。
- v0.3 从已有检查器标签扩展点接入项目任务与 Git；先明确任务运行/取消/输出及 Git 写操作契约，继续复用 daemon 进程归属、日志与状态机制。v0.2 不先做这些功能。

清理记录：本次 mock 按启动时记录的 PID / lstart / command 核对后停止；验收 daemon 经 API 关闭，受管身份复查无残留。已删除 `codex/acc`、`perf`、`mock`、`bin`、`acceptance-project` 和一次性截图辅助脚本；保留 36 张 PNG、日志、JSON 证据与 release `.app`。见 `.devpanel-dev/codex/d-cleanup.json`。

## 真实使用反馈补充：详情与简洁选项（2026-10-20）

本轮按用户要求完成日志为主的详情模式、堆栈折叠与按需说明。没有修改接口或个人 daemon，也没有重启用户的项目。README 已改为中文，并补充直接双击启动、切换模式、问号说明等日常操作。

- 总览/详情切换：详情左侧 220 pt 服务导航，右侧扩展日志；普通启动记住布局，⌥⌘D 可切换。自动往返检查确认 NSTextView 实例、服务、运行、搜索均未丢失。
- 选项：默认名称、值、问号；enum 下拉，说明/编写者/引用/编辑/删除按需展开，错误和冲突保持直接可见。宽窗口自适应多列。900 pt 总览不再裁切列，项目汇总与详情仍能查看资源。
- 折叠：连续至少 3 行的 Java / JavaScript 堆栈；保留原因链，点击展开、全量展开、搜索隐藏行并自动展开、选区/全量复制原文。48 行合成异常折叠为 7 行，点击第一段后为 30 行，搜索第二段后为 18 行，全部展开为 48 行；原文复制核对均通过。
- 校验：Swift 226 项 / 34 suites，测试执行 1.200 s；debug/release 编译零警告。`pnpm typecheck` 通过；`pnpm test` 132 项（daemon 39 / CLI 16 / Web 52 / mock 25），daemon 38.9 s、CLI 3.0 s、Web 0.388 s、mock 8.0 s。
- release 压力检查：隔离 mock 连续注入 10 万行，内存窗口保持 5 万行；138 MiB、搜索 24.1 ms、增量同步最慢 46.8 ms、全量重建 231.7 ms、40 屏滚动平均 3.0 ms。复制原文和搜索命中可见检查通过。debug 压力过程中的首次检查曾碰到命中行被滚动淘汰，记录保留；release 完整接收后的检查通过，不将 debug 瞬时检查视为稳定性能数据。
- 产物：`apps/mac/build/DevPanel.app`，release、本机 ad-hoc 签名，实际 bundle 连接隔离 mock 完成截图。

截图与输出均保留在 `.devpanel-dev/codex/detail-evidence/`：

| 文件 | 结果 |
| --- | --- |
| `detail-dark.png` / `.log` | 日志主导布局、折叠原因链、往返布局状态核对 |
| `detail-expanded.png` / `.log` | 与实际链接点击共用的代理路径展开第一段 |
| `detail-search.png` / `.log` | 隐藏行命中自动展开并高亮 |
| `detail-all.png` / `.log` | 全部原文展开 |
| `options-light.png` | 默认简洁选项 |
| `options-help.png` | 按需说明、引用、编辑与删除 |
| `detail-narrow.png` / `overview-narrow.png` | 900×650 窗口下两种模式 |
| `option-popup.png` / `option-error.png` / `option-secret.png` | 简洁弹窗、数值错误不隐藏、敏感值不回显 |
| `release-live-flood-bench.log` | release 10 万行输入压力实测 |

需要用户亲自确认：退出旧界面后双击上述新 App，点“详情”、折叠链接、选项问号，并试一次 ⌥⌘D。自动验收使用真实渲染和同一点击代理，未代替用户实际鼠标/键盘操作。只需重开界面，后台 daemon 与项目不需重启。折叠目前不合并重复错误，不识别任意语言的多行异常；后续可按实际日志增加识别规则。

## v0.2 review 收尾（2026-10-21）

采样健壮性已完成：失败后退避 30 秒重建 helper、ps 保持 250ms 发现、build/setup/daemon 异步预编译且服务启动不等待 clang。恢复与短命父进程 detached 子进程清理回归已通过。footprint、工具资源、选项展示分组与 mock 同步完成；两项兼容契约变更均由用户追认。未开始 v0.3。

### 资源实测更新

主内存改为 footprint，以下为 2026-10-21 隔离数据目录中已保存的实测，已核对原始 JSON；不能与此前 RSS 列直接比较，也不宣称长期保证。CPU 100% 为一个逻辑核心。

| 场景 | CPU | footprint | 证据（`.devpanel-dev/codex/`） |
| --- | ---: | ---: | --- |
| 三个空闲服务，仅后台，15 秒窗口 | daemon 0.614% + helper 0.396% = 1.010% | 后台 50.05 MiB，其中 helper 1.31 MiB | `tool-perf.json` |
| 一个空闲业务服务 + release 界面，短时样本 | 界面 2.893% + 管理 0.946% + 辅助 0.713% = 4.553% | 工具 76.22 MiB，业务服务另列约 13 MiB | `tool-ui-idle-result.json` / `tool-resources-idle.png` |
| 持续输出日志的三进程树 + release 界面 | 界面 22.1%，工具 24.6% | 界面 43.3 + 管理 43.2 + 辅助 1.7 ≈ 88.3 MiB | `tool-ui-result.json` / `tool-resources.png` |

工具合计严格区分界面、daemon、常驻 helper；原生故障回退的短命 ps/lsof 无完整工具合计，显示不可用。一次性编译/CLI 不属于稳定周期样本。恢复测试日志与本轮逐项检查在 `.devpanel-dev/codex/closeout/`。

### 紧凑模式验收

总览表在 900×650、检查器打开时仍显示完整 CPU/内存，先隐藏命令、时长与端口，状态/长名称可省略并保留悬停说明。内存预留 RSS 后缀，数值优先于“部分”文字。456–1200 pt 表宽逐点验证列宽合计不溢出。release 截图已检查：`closeout/compact-900x650-{dark,light}.png` 与 `compact-1180x760-dark.png`；满足 §3.2，无需修改 CPU/内存必须显示的设计要求。

### LISTEN 测试收尾

确定复现了旧测试的 IPv6-only 随机端口未预留 IPv4 问题：IPv4 占用时服务 EADDRINUSE 退出，启动 partial；并非端口采样丢失。改用受管服务 `listen(0)` 原子分配，再以该运行的启动日志核对端口，保持非受管监听隔离和停止断言。原始偶发那次没有服务日志，无法追溯认定；本次失败与成功证据及 native/ps 各 10 次复跑在 `closeout/listen-*.log`。

### 最终逐项验证

每项提交前均通过 Swift build/test 与根目录 pnpm typecheck/test。Swift 编译零 warning；全仓 build 与 release `.app` 打包、签名检查通过。测试全部使用隔离 DEVPANEL_HOME，没有重启真实 daemon 或项目。下表 Swift 执行时间取 Swift Testing 输出，命令墙钟包括增量编译；pnpm 为全仓命令墙钟，各包并行不相加。

| 项目序号 | Swift 数量 / 测试执行 | Swift test 命令墙钟 | pnpm 数量 / 命令墙钟 | typecheck 墙钟 |
| --- | --- | --- | --- | --- |
| 1 | 242 / 2.231s | 4.769s | 141 / 39.451s | 1.648s |
| 2 | 242 / 2.225s | 3.926s | 143 / 38.735s | 2.342s |
| 3 | 242 / 2.242s | 6.110s | 143 / 39.894s | 1.670s |
| 4 | 242 / 2.238s | 3.377s | 143 / 38.317s | 1.338s |
| 5 | 242 / 2.230s | 3.162s | 143 / 38.912s | 1.372s |

最终 pnpm 143 = daemon 48 + CLI 16 + Web 52 + mock 27；Swift 242 / 37 suites。

采样恢复证据：`closeout/recovery-red.log` 保存修改前真实 helper 首次请求超时后永久停留 ps 的断言失败；`recovery-green.log` 三项通过（2.946s）：一次真实请求超时后回退；可控时钟在 29,999ms 仍退避、30,000ms 启动新 helper；编译未就绪时扫描先完成、编译失败可重试；ps 中 900ms 父进程退出后 detached 子进程仍受管且停止无残留。恢复测试将单次请求超时设为 1s，生产超时为 200ms，30s 退避用测试时钟推进，无需真实等待。轮询仍受采样窗口限制，不承诺发现任意短到未被观察、完全脱离谱系的进程。

端口专项 native 10/10（7.035s），ps 10/10（8.877s）。最终另检查 `compact-900x650-light-rss.png`，数值及 RSS 后缀均完整；窄列状态文字有省略，保留悬停说明。已从 §7 删除没有内容的“设置”菜单并注明原因。五项收尾完成，未开始 v0.3。
