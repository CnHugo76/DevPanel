你接手 DevPanel v0.2 剩下的全部工作，包括原来由 Claude 负责的前端部分（macOS 原生程序 `apps/mac`、mock `tools/mock-daemon`）。仓库：/path/to/DevPanel，分支 `main`，起点提交 `9b6a196`。macOS 27、Xcode 27.1（已选中）、Swift 6.4、Node 24、pnpm 12。

请按下面的顺序把任务全部做完，每完成一个任务就自检并单独提交一次（本地 `main`，不推送）。遇到需要用户决定或用户亲自操作的事情，记下来放进最终汇报，不要自行决定，也不要卡住其他任务。

---

## 0. 先读（全部读完再动手）

1. `AGENTS.md`（注意最后的“v0.2 收尾交接”一节：本阶段你可以修改 `apps/mac/` 和 `tools/mock-daemon/`）。
2. 产品：`docs/product-design-v0.1.md`、`docs/product-design-v0.2.md`（后者覆盖前者冲突部分）。
3. 界面：`docs/ui-design-v2.md`（原生程序规格）、`docs/ui-mockup-v2.html`（视觉稿，8 个场景，可在浏览器打开对照）、`docs/ui-design.md`（v1 中仍适用的文案、状态、缺失值、断连规则）。
4. 计划：`docs/plan-v0.2.md`（F0–F3、F5 已完成；剩 F4、F6 和联调）。
5. 契约：`contract/api.md`（尤其 §3.1 选项及其细节澄清）、`packages/contract/src/index.ts`、`contract/CHANGES.md`。
6. 原生程序：`apps/mac/README.md`（结构、`--self-check`、`--snapshot` 全部参数），然后浏览 `apps/mac/Sources`。

## 1. 现状（已完成并已提交）

| 部分 | 内容 | 测试 |
| --- | --- | --- |
| 后端 | 选项（校验、启动时替换与 shell 转义、设置者、覆盖保护、三条路由、CLI `param`）、真实监听端口、遮盖与 socket 路径修复 | `pnpm test` 全仓 132 个 |
| mock | v1.1 选项与端口、贴近真实的种子选项（order-service 的 profile / apiPort / host，ml-api 的 port / reload / hfToken） | 含在 132 内 |
| F1 地基 | `DevPanelKit`：契约 Codable 类型（未知枚举值落到 `.other`）、`Discovery`、`DaemonClient`（URLSession + SSE）、`AppModel`（`@Observable @MainActor`，事件流驱动、退避重连、25 秒看门狗）；`--self-check`；`scripts/bundle.sh` | `swift test` |
| F2 总览 | 项目卡片、选项标签（只显示）、固定列宽服务表、真实端口胶囊、启停与结果条、停止超时与强制停止、紧凑模式、搜索、断连横幅、空状态、`--snapshot` | 同上 |
| F3 检查器 | 日志（TextKit 2 `NSTextView`、ANSI、搜索、跟随、历史运行、5 万行上限与 `before` 补载、`LogSession` 的 runId / 代次核对）、运行记录（当次选项值与替换后命令）、命令与环境（只读 + “编辑…”）、断连时冻结计时与变灰 | 同上 |
| F5 编辑 | 添加 / 编辑项目 sheet（shell 拆分、后台命令警告、替换预览、环境变量敏感值、失焦校验、revision 冲突、`keptUserValues` 提示）、移除项目 | `swift test` 共 206 个 |

### 你会用到的接口（来自各任务交接）
- `AppModel`：`connection`（status / retryAt / lastEventAt / syncedAt / lastError / staleDiscovery）、`daemon`、`projects`、`stats`、`operations`、`configs`（按 revision 自动拉取；`params(_:)`、`serviceConfig(_:_:)`；写操作后用返回的 `Project` 调 `storeConfig(_:)`）、`selection` / `select(_:)`、`runAction(_:)`、`actionResults`、`forceStopProcessCount`、`shutdownDaemon(stopServices:)`、`startDaemon()`、`displayNow(_:)`（所有按当前时间计时的显示都要用它）、`isStale`、`inspector`（`tab`、`wrap`、`runChoice`、`fetchedRuns`、`runDetails`、`logs`、`search`）、`openLogs(_:)`、`showRunLog`、`chooseRun`、`refreshRuns`、`loadRunDetail`。新动作写在 `AppModel` 的扩展文件里，视图不直接调 client。任何对契约枚举的 `switch` 都要处理 `.other`。
- `EditorPresenter`（环境对象）：`openNew()`、`edit(id)`、`remove(id)`、`locate(id)`、`show(Toast)`。
- `InspectorView.swift` 里 `tabContent` 的 `.options` 分支目前是 `OptionsTabPlaceholder`（F4 替换）。`InspectorTab.visible` 预留了 v0.3 的“任务”“Git”。
- 复用：`CommandPreview.make(argv, params:)`、`unknownKeys(in:params:)`、`ParamConfig.displayValue`、`ParamChips`、`ProcessPalette`、`ForceStopTarget` / `.forceStopConfirmation`、`ViewPreferences`、环境值 `isStale`。
- `--snapshot`：不需要屏幕录制权限，把窗口自身渲染成 PNG；参数见 README（`--select`、`--tab`、`--perform`、`--open-editor`、`--editor-*`、`--remove-project`、`--log-*`、`--delay`、`--appearance`、`--size`、`--second`…）。`cacheDisplay` 不渲染模糊 / 饱和度效果，需要出现在截图里的状态请用显式颜色；真正的 `.sheet` 是独立窗口，截图里用内联方式绘制。

---

## 任务 A：F4 选项编辑（ui-design-v2 §5）

1. **选项标签点击 → 编辑弹窗**（总览卡片里的 `✦ 标签 值 ▾`）：
   - 标题为选项名称；副标题 `✦ AI 编写 · 10/20` 或 `你修改于 11:02`（依据 `setBy` / `valueUpdatedAt` / `describedBy`）。
   - 说明文字（`description`）。
   - 控件按类型：`enum` 单选列表，每项显示值、标签和该值的说明（≤4 项且都没有说明时可用分段控件）；`string` 文本框（等宽）；`number` 数字框加步进器，按 `min` / `max` 校验；`boolean` 开关。
   - secret 选项：不回显，只能“设置新值”；留空即不改。
   - 底部：“删除此选项”、提示“改动在下次启动时生效”、“完成”。改值即保存：`PATCH /projects/:id/params/:key`（带 `ifRevision`）。**不提供“保存并重启”。**
   - 错误按契约 §3.1 澄清处理：404 `PARAM_UNKNOWN`（选项已被别人删除 → 提示并刷新）、422 `CONFIG_INVALID`（`PARAM_INVALID` 显示在控件下方）、409 `REVISION_MISMATCH`（提示“配置已被其他客户端修改”，刷新后保留用户刚输入的值让其重试）。
2. **检查器“选项”标签**（替换 `OptionsTabPlaceholder`）：列出**本服务引用到的**选项（依据 `usedBy`，项目级 `*` 引用也算），每个一张卡片：名称、`${key}`、设置者与时间、说明、控件（与弹窗共用组件）、引用位置（“用于：后端 命令 `-Dspring-boot.run.profiles=${profile}`”，并用当前值显示替换后的片段）。名称和说明可就地编辑（编辑后 `describedBy` 变为 user）。
3. **添加选项**：卡片 ⋯ 菜单与检查器“＋ 添加选项”：填写 key（格式 `/^[a-zA-Z][a-zA-Z0-9_]{0,31}$/`，本地先校验）、名称、类型、值，可选说明、可选值（enum）、min / max（number）、敏感。`POST /projects/:id/params`。添加后提示“在命令或环境变量中用 `${key}` 引用它（编辑项目…）”，并提供打开项目编辑 sheet 的按钮。
4. **删除**：未被引用直接确认删除；被引用时确认框展示删除后的命令 / 环境（当前值写回，绿色标出），按钮“删除并写回”（`inline=true`）；secret 被命令引用时说明为什么不能写回（`PARAM_IN_USE` + `reason: secret`），引导用户先编辑命令。
5. **“下次启动生效”标记做精确**：F2 目前用 `configChangedSinceStart` + `valueUpdatedAt` 推断标签是否“待生效”。请改为对比当前运行的 `RunDetail.params`（该服务实际使用的值）与当前保存的值，按需拉取 / 缓存 run detail；拉取失败时回退到原推断。
6. 纯逻辑（类型校验、key 校验、显示文本、写回预览、待生效判断）放 DevPanelKit 并写 Swift Testing 测试。

截图（至少）：enum 弹窗（深 / 浅）、number 越界错误、secret 设置、检查器选项标签、添加选项、删除并写回确认、secret 拒绝写回、revision 冲突提示、“待生效”标记在改值后出现、重启后消失。

## 任务 B：F6 程序级行为（product-design-v0.2 §2、ui-design-v2 §7）

1. **窗口与退出**：关闭窗口只关窗口，管理服务与项目继续运行，首次关闭提示一次“DevPanel 会在后台继续管理项目，可从 Dock 重新打开”（记住已提示）；点 Dock 图标重新打开窗口；⌘Q 只退出界面。
2. **菜单**：
   - DevPanel：关于、停止所有服务并退出管理服务…（有运行中服务时二次确认；调用 `shutdownDaemon(stopServices: true)`；失败时如实显示原因，管理服务保持运行）、退出 DevPanel（⌘Q）。
   - 文件：添加项目（⌘N，用 `CommandGroup(replacing: .newItem)` 调 `EditorPresenter.openNew()`，并去掉标题栏按钮上重复的快捷键）、编辑项目…、移除项目…（作用于选中服务所在项目）。
   - 服务：启动 / 停止（⌘↩，按选中服务当前状态切换，重复按下不重复发送）、重启（⌘R）、强制停止（仅停止超时时可用，带确认）、打开日志（⌘L）。
   - 显示：显示 / 隐藏检查器（⌥⌘I）、搜索（⌘F：检查器打开且在日志标签时聚焦日志搜索，否则聚焦总览搜索）。
   - 断连或无选中时相应菜单项禁用。
3. **系统通知**（`UserNotifications`，需要以 `.app` 运行；首次需要时请求权限）：仅对**非用户主动**结束发送——运行以 `self-exit` 结束且状态为 `failed`、以 `daemon-lost` 结束、服务进入 `unknown`。用户主动停止 / 强制停止、`exited(0)` 不通知。文案如“reg-radar · 后端 异常退出（1）”。点击通知打开窗口并 `openLogs` 到该服务。同一运行只通知一次；程序启动时的首个 snapshot 不补发历史通知。
4. **Dock 角标**：显示当前处于 `failed` / `unknown` 的服务数，0 时清空。
5. **管理服务未运行**：已有提示与“启动管理服务”按钮；补充：从 Finder 启动时 PATH 很短，启动按钮应优先使用 `~/.local/bin/devpanel`，找不到时提示运行 `pnpm setup:cli`；启动失败时显示 CLI 返回的错误信息。
6. **收尾小项**（各任务遗留）：
   - “定位到项目”（F5 的 created:false / 打开已有项目）时总览滚动到该项目（`ScrollViewReader`）。
   - 查看已结束的运行时，日志“跟随”按钮禁用。
   - 失败状态胶囊在窄列被截断时，`help` 显示完整文字（确认已有）。
   - 空状态时保留工具栏搜索框（与视觉稿一致）或在汇报中说明不保留的理由。

截图（至少）：首次关窗提示、菜单（如无法截菜单，说明替代验证方式）、停止所有服务并退出的确认框、通知点击后打开日志的结果状态、Dock 角标（如无法截图，用日志 / 测试证明计数逻辑）。

## 任务 C：与真实 daemon 联调与验收

1. 用**临时、短路径**的数据目录启动真实 daemon（例如 `DEVPANEL_HOME=.devpanel-dev/acc`，`DEVPANEL_PORT=0`；macOS socket 路径不能超过 103 字节），用 `packages/daemon/test/fixtures/` 中的脚本组装一个两三个服务的验收项目，其中要有：被选项引用的端口与监听地址（`listening.mjs`）、会派生子进程的服务、忽略 SIGTERM 的服务、会异常退出的服务。由“AI”（CLI）注册并带上选项。
2. 用打包后的 `DevPanel.app`（`DEVPANEL_HOME` 指向该目录）逐条验证并截图 / 记录命令输出：
   - `docs/product-design-v0.2.md` §7 的全部 8 条；
   - `docs/product-design-v0.1.md` §16 中与界面相关的条目（UI 启动 / CLI 查询同一运行、CLI 启动 / UI 查看、停止超时与强制停止、重启中停止、程序自行退出、断连显示过期、移除项目不删文件）；
   - 最关键的一条：CLI 启动 → 程序里看到同一运行、日志、资源、真实端口 → 在程序里停止 → CLI 确认已停止、按 PID + 启动时间核对无残留。
   - 程序自身空闲 CPU / 内存（release 构建，无项目运行与有 3 个服务运行两种情况），写进 `docs/plan-v0.2.md`。
3. 你无法用鼠标真实点击窗口时，用 `--snapshot` 的 `--perform`、`--select`、`--tab` 等参数驱动，并在汇报里列出**需要用户亲自点一遍的交互清单**（例如：⌘F、Enter / ⇧Enter 跳转、双击服务行、滚轮停止跟随、悬停时间戳、真实的 sheet 与 NSOpenPanel、通知点击、Dock 点击重开、菜单快捷键）。

## 任务 D：文档与收尾

1. 更新 `docs/plan-v0.2.md`：每项的完成状态、验收结果、实测数据、剩余问题。
2. 更新 `apps/mac/README.md`：新增参数、菜单与快捷键、通知；以及“用户如何在自己的机器上使用”的步骤：`pnpm setup:cli` → `devpanel daemon start`（或 `devpanel daemon install` 开机自启）→ `apps/mac/scripts/bundle.sh` → 打开 `apps/mac/build/DevPanel.app`（可选拷到 `/Applications`）。**不要替用户安装到 `/Applications`、不要替用户执行 `daemon install`、不要连接用户正在运行的真实 daemon。**
3. **Web 界面（`apps/ui`）是否退役**：不要删除。在汇报里给出建议（保留 / 退役、daemon 是否停止托管页面、对契约变更的维护成本），由用户决定。
4. 如发现契约需要变化：按 `AGENTS.md` 在 `contract/CHANGES.md` 写提案并在汇报中列出；在用户确认前不改契约，按现有契约实现或记为限制。

---

## 硬性规则
- **安全**：只对能核验属于本次运行的进程（pid + 启动时间）发信号；停止你启动的进程时只按你启动时记录的 PID（先核对 PID 对应的命令行确实是你启动的那个），不要按端口反查后杀进程，**不要用 pkill / killall 按名称杀进程**（用户机器上有其他项目的 Vite 等进程，以及用户正在使用的真实 DevPanel daemon）。
- **数据**：测试与验收一律用临时 `DEVPANEL_HOME`（短路径），**绝不**读写 `~/Library/Application Support/DevPanel`，不注册用户的真实项目，不修改 `~/.local/bin` 以外的用户环境（`setup:cli` 也请用 `--bin-dir` 指到临时目录做测试）。
- **范围**：只做 v0.2；项目任务（Maven 等）与 Git 属于 v0.3，不做，但别破坏已预留的扩展点。
- **质量**：`cd apps/mac && swift build && swift test`（当前 206 个，不能退化，0 编译警告）、根目录 `pnpm typecheck` 与 `pnpm test`（当前 132 个）每次提交前都通过；`scripts/bundle.sh` 能产出可运行的 `.app`。
- **界面一致性**：颜色、间距、字号对照 `docs/ui-mockup-v2.html`；文案与禁用语沿用 v1（不出现“健康”“就绪”等业务结论；缺失值绝不显示 0）。
- **提交**：每个任务（A / B / C / D，可再细分）一个或几个清晰的提交，信息写明做了什么；不推送、不改写已有历史、不创建其他分支（如需并行可用临时工作树，合并后删除）。
- 临时文件和截图放到 `.devpanel-dev/codex/`（已被 git 忽略），结束后清理不再需要的临时数据目录，保留截图供用户查看。

## 最终汇报（发给用户）
1. 每个任务的完成情况与提交列表。
2. 新增 / 修改的主要文件与结构说明。
3. 测试结果（Swift 与 pnpm 的总数、耗时）。
4. 截图清单（绝对路径 + 一句说明），以及与视觉稿仍有差异的地方。
5. 任务 C 的逐条验收结果（通过 / 未通过 / 需用户确认），附关键命令与输出；程序空闲资源实测。
6. **需要用户亲自操作或决定的事项**：手动交互清单、Web 界面去留建议、契约提案（如有）、真实项目验收的建议步骤。
7. 已知限制与 v0.3 的建议起点。
