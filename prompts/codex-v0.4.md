你负责实现 DevPanel v0.4 的前后端（daemon、CLI、mock、macOS 原生程序）以及发布包。仓库：/path/to/DevPanel，分支 `main`。macOS 27、Xcode 27.1、Swift 6.4、Node 24、pnpm 12。

阶段按两条线和一项独立工作拆分：

- **监督线**：阶段 1（操作来源与动态，v1.3-C）→ 阶段 2（托管规则，v1.3-D）。
- **AI 闭环线**：阶段 3（日志摘要，v1.3-B）→ 阶段 4（就绪，v1.3-A）。
- 阶段 5（安装与分发）独立进行。
- 阶段 6 联调验收。

两条线互不依赖，可以在临时工作树并行，各自合并回 `main` 后删除工作树。每个阶段（可再细分）自检后单独提交到本地 `main`，不推送。遇到需要用户决定或用户亲自操作的事项，记进最终汇报，不要因此卡住其他阶段。

---

## 0. 先读（全部读完再动手）

1. `AGENTS.md`：特别是“用户的稳定版”一条和“v0.3 分工”一节。v0.4 沿用同一分工：你实现，Claude 负责设计与 review。
2. 产品：`docs/product-design-v0.4.md`（第 1 稿）。v0.1 ~ v0.3 中未被覆盖的约定继续有效。
3. 契约：
   - `contract/api.md` 的 §1.1 第 7 条、§2 路由表末尾 6 条、§3.1 占位符范围、§4.2 最后一条、§4.3 第 4 步、§9 CLI 与退出码 10–12、**§13 就绪**、**§14 日志摘要**、**§15 操作来源与动态**、**§16 托管规则**；
   - `packages/contract/src/index.ts` 中标注 v1.3 的类型；
   - `contract/CHANGES.md` 中 v1.3-A ~ v1.3-D（已生效）。

   契约已经写好，你不需要改；发现问题按 `AGENTS.md` 写待决提案。
4. 界面：`docs/ui-design-v4.md` **尚未写**。原生部分以产品文档的界面条款为准（§2.5、§3.4、§4.4、§5.6、§7），视觉与交互沿用 `docs/ui-design-v3.md` / `docs/ui-design-v2.md` 的既有模式。不要自创新的页面结构；拿不准的布局按最小改动实现，并列进汇报。如果你开始原生部分时 ui-design-v4 已经出现，以它为准。
5. 现有实现：`apps/mac/README.md`、`docs/backend-design.md`、`docs/plan-v0.3.md`（结构、实现记录、资源基线的测法）。

**关于契约里的可选字段**：响应中新增的字段（`Operation.actor`、`RunSummary.startedBy` / `ready`、`TaskRunSummary.startedBy`、`ExitInfo.requestedBy`、`ServiceView.hold` / `locked`、`ProjectView.policy`、`Limits.activityKeptPerProject`）在 `index.ts` 里是可选的，只为兼容旧 daemon、让未实现时仍能通过类型检查。

- **v1.3 daemon 必须总是返回它们**（api.md 有明文）。daemon 内部可以用更严格的类型保证这一点。
- mock 同样总是返回。
- 原生客户端按可选解码，连到旧 daemon 时显示“未知”，不崩溃。
- `ParamReference.where` 新增 `'ready'`，按开放枚举处理。
- 不要把可选改为必填；认为需要时写提案。

`apps/ui`（旧 Web 界面）只需继续通过类型检查和现有测试，不实现新功能。

## 1. 硬性规则

- **不碰用户的稳定版**：
  - 不调用 `~/.local/bin/devpanel`，不运行不带 `--bin-dir` 的 `setup:cli`；
  - 不修改 `~/.local/share/devpanel/stable`、`/Applications/DevPanel.app`；
  - 不停止或重启用户正在运行的 daemon（它使用真实数据目录 `~/Library/Application Support/DevPanel`）。

  开发、测试、验收一律用 `node packages/cli/src/main.ts`（或你构建出的开发包）加临时的短路径 `DEVPANEL_HOME`，例如 `.devpanel-dev/v04-xxx`，socket 路径 ≤ 103 字节。
- **不写用户的 `~/.local/bin`**：阶段 5 的“安装 CLI”引导，开发和测试时只能指向临时目录。目标位置已有文件或链接时（用户的稳定版就在那里），必须先显示并询问，绝不静默替换。
- **进程安全**：
  - 只对 pid + 启动时间核验属于本次运行的进程发信号；
  - 停止你自己启动的进程，只按启动时记录的 PID（先核对命令行），不按名称、不按端口；
  - 测试结束不得留下孤儿进程。
- **敏感值**：动态（§15）的配置差异、日志摘要、启动报告、CLI 输出中都不得出现敏感值。每个阶段都要有带 secret 环境变量 / secret 选项的回归测试。
- **托管规则不是安全边界**（§16 最后一条）：不要为它引入新的认证机制，也不要在文档里把它说成安全功能。
- **范围**：只做 v0.4 第 1 稿。不做：
  - HTTP 就绪探测、持续健康检查、按就绪顺序启动、自动重启、正则就绪；
  - AI 诊断、审批请求、按 agent 名称区分权限、回滚配置；
  - 签名、公证、Homebrew、自动更新、Linux / Windows 安装包；
  - 仓库内配置文件、MCP、多 worktree 实例；
  - Maven / Git 视图的任何扩展。
- **不发布**：不推送，不创建 GitHub Release、标签或仓库；只在本地产出发布包。
- **质量**：
  - 每次提交前 `pnpm typecheck`、`pnpm test`、`cd apps/mac && swift build && swift test` 全部通过，且 0 编译警告；
  - `apps/mac/scripts/bundle.sh` 能产出可运行的 `.app`；
  - 保持测试的 `--test-timeout` / `--test-force-exit`；
  - 测试不访问网络。
- 临时文件、截图放 `.devpanel-dev/codex/v04/`（已被 git 忽略）。实现与验收记录写进新建的 `docs/plan-v0.4.md`，格式参照 `docs/plan-v0.3.md` 的“实现与验收记录”。

## 2. 阶段

### 阶段 1：操作来源与动态（v1.3-C）

**daemon**
- 解析 `X-DevPanel-Agent`：格式不合法 → 400；`ui` 请求忽略。
- 所有记录点填 `Actor`：`Operation.actor`（`source` 恒等于 `actor.client`）、`RunSummary.startedBy`、`TaskRunSummary.startedBy`。
- `ExitInfo.requestedBy`：`user-stop` / `force-stop` / `start-cancelled`，以及任务运行被取消时，填发起方；其他原因为 null。
- 管理服务自身发起的动作（例如重启后的核验收尾）用 `client: 'daemon'`。
- 持久化；旧记录读出为 null。

**动态**
- 按 §15 实现写入时机：
  - operation 终态；
  - 注册 / 更新 / 选项路由保存成功（幂等注册 `created:false` 不写）；
  - 任务运行结束；
  - `policy` 条目留给阶段 2。
- 配置差异复用注册冲突时的 `ConfigDiffEntry` 生成逻辑，最多 100 条，加 `changesTruncated`，敏感值一律为 `{ secret: true }`。
- 每项目保留 `activityKeptPerProject`（500）条；按 `before` / `limit` 分页；删除项目时一并删除；不新增事件类型。

**CLI**
- 全局参数 `--agent`；环境变量 `DEVPANEL_AGENT`，参数优先；不合法时退出码 2；不推断名称。
- 新增 `activity` 命令。
- `project rules` 输出中加入“在 agent 配置里设置 `DEVPANEL_AGENT`”的说明。

**mock**
- 同步实现。
- 种子动态覆盖以下来源：`claude-code`、`codex`、未带名称的 CLI、界面、daemon。
- 至少包含一次带敏感项的配置修改（必须被遮盖）。

**原生**
- 发起方显示规则：`ui` → “你”；`claude-code` → “Claude Code”；`codex` → “Codex”；其他名称原样显示；`cli` 无名称 → “命令行”；`daemon` → “DevPanel”。
- 服务行与服务检查器：显示“由 X 启动 · 相对时间”，已停止时显示“由 X 停止”；运行记录显示发起方。
- 项目检查器新增“动态”标签：
  - 新 → 旧，滚动加载；
  - 配置变更条目可展开差异；
  - 条目可跳到对应运行的日志；
  - 只在标签可见时刷新：收到 `operation` / `project.upsert` 后合并请求，不轮询。
- 通知规则不变：AI 发起的操作与 CLI 停止都不通知。

**测试**
- 请求头校验；三种停止来源（界面停止 / CLI 带名称停止 / 自行退出）的 `requestedBy`。
- 任务取消方；daemon 重启后发起方保留。
- 动态：写入时机、幂等注册不写、敏感值遮盖、100 条截断、保留上限、分页、删除项目。

### 阶段 2：托管规则（v1.3-D，依赖阶段 1）

**daemon**
- 每项目的 `ProjectPolicy` 独立于 `ProjectConfig` 存储并持久化。默认值：`holdAfterUserStop: true`、`agentForceStop: 'deny'`、`lockedServices: []`。
- `GET/PUT /projects/:id/policy`、`DELETE …/services/:serviceId/hold`：写操作只接受 `ui`，否则 403 `FORBIDDEN_CLIENT`；`lockedServices` 含不存在的服务 → 422。
- 注册 / 更新 / 校验既不读也不写规则；更新配置删除服务时，自动从 `lockedServices` 移除。
- 暂停的产生与解除严格按 §16。
- 拒绝判断放在操作进入服务队列**之前**：
  - 被拒目标的 outcome 为 `failed`，带 `POLICY_DENIED` 和 `details.reason`；
  - 不创建运行、不发信号；
  - **被拒绝的 stop / force-stop 不参与 §4.2 停止优先**，不能取消排队中的启动。
- `overrideHold` 只对 `cli` 生效，对锁定无效；成功越过并解除暂停时，operation 动态条目标记 `overrideHold: true`。
- 规则变化与暂停的产生 / 解除写 `policy` 动态，并触发 `project.upsert`。

**CLI**
- `start|restart --override-hold`。
- 只读命令 `policy`；`status` 显示暂停 / 锁定。
- 退出码 12 严格按 §9：失败的目标全部为 `POLICY_DENIED` 才是 12，例如项目级启动时 backend 启动成功、frontend 被锁定 → 12；与其他失败混合时按 6 / 1。

**mock**
- 规则与拒绝行为。
- 种子数据：一个暂停中的服务、一个锁定的服务。

**原生**
- 服务行：
  - 暂停时显示“⏸ AI 需你同意”，悬停显示“你在 HH:mm 停止了它”，带“允许 AI 启动”按钮；
  - 锁定时显示锁图标；
  - 右键菜单加“锁定 / 解锁”。
- 项目的“AI 权限”设置：停止后暂停开关、允许 AI 强制停止开关、已锁定服务。
  - 它不属于项目配置，保存走 policy 路由，与“编辑项目”的配置保存分开。
  - 放在项目 ⋯ 菜单进入的独立 sheet，或编辑 sheet 中的独立分区，二选一，汇报里说明。
- 界面启动会由 daemon 自动解除暂停，界面不需要额外请求。

**测试**
- 界面停止 → CLI start 被拒、未 spawn。
- `--override-hold` 能启动且有动态记录；界面启动 / 删除暂停后 CLI 可以启动。
- 锁定时四种动作都被拒，界面不受影响。
- 被拒的 stop 不取消排队中的 start。
- `agentForceStop` 两种取值；`holdAfterUserStop` 改为 false 时清除全部暂停。
- daemon 重启后暂停保留；退出码 12 / 6 的判定；CLI 写规则得到 403。
- 界面停止与 CLI 启动并发的竞态。

### 阶段 3：日志摘要（v1.3-B）

**daemon**
- `GET /runs/:runId/digest` 对服务运行与任务运行通用。
- 错误标题、堆栈行、折叠、签名去重、`repeat`、1 KiB 截行、预算分配顺序、`omitted`、`truncated`、`afterSeq` **逐字**按 §14 实现；正则就用 §14 给出的写法。
- 只读、按请求计算、不缓存。读取过程中内存有上界，不把 32 MiB 日志整体载入成大对象。
- 记录在 32 MiB 日志上的耗时。

**文本格式**
- 按 §14 的文本格式实现。CLI（TypeScript）和原生“复制摘要”（Swift）各有一份格式化实现。
- 两边必须用**同一组 golden 样例**测试：输入 `LogDigest` JSON，对比期望文本。样例放在一处（不要放进 `contract/`、`packages/contract/`），两边测试读同一批文件。

**CLI**
- `logs --digest [--after-seq] [--max-bytes] [--json]`；普通 `logs --after-seq`（对应 `?after=`）。
- `--service` 与 `--run` 二选一。

**mock**
- 摘要路由；可以复用同一算法，也可以用固定样例。
- 种子日志含：重复 50 次的同一异常、含 `Caused by` 的长 Java 堆栈、Python Traceback、只写 stderr 的正常输出。

**原生**
- 日志工具栏增加“复制摘要”：对当前查看的运行请求默认预算的摘要，按文本格式复制，复制后有轻提示。
- 现有的堆栈折叠规则改为与 §14 一致（保留标题、前 5 个 `at` 帧、每个 `Caused by` / `Suppressed` 及其后 2 帧）。
- 搜索、复制原文的现有行为保持不变（`apps/mac/README.md` 中的描述）。

**测试**
- 识别规则 (a)(b)(c) 的正例与反例：仅 stderr 不算，`NO_ERROR` / `ERRORS` 这类非独立单词不命中。
- 堆栈结束判定；Python 缩进代码行。
- 数字归一化去重、`repeat`、预算顺序与 `omitted`、单块超预算截取。
- `truncated`、`afterSeq`、任务运行、ANSI、超长行。

### 阶段 4：就绪（v1.3-A，依赖阶段 3）

**配置校验**
- `contains` 1–5 项、每项 1–200 字符；`port` 为 1–65535 或整值 `"${key}"` 指向 number 选项；`timeoutSec` 1–900。
- `usedBy.where = 'ready'`。
- 删除被 `ready.check.port` 引用的选项并 `inline=true` 时，把当前数值写回为 number。

**契约未写明的三点**：按下面的解释实现，同时各写一条待决提案，在汇报里列出。
1. `ready.check.port` 引用 secret 选项：建议按 `PARAM_INVALID` 拒绝。
2. inline 写回 ready.port：按上面的规则，写回为 number。
3. §14 规则 (a) 的 `ERROR` / `FATAL` / `SEVERE` 是否区分大小写：建议区分（只认大写），避免把普通文字里的 error 当成错误。这一条属于阶段 3，在阶段 3 实现时写提案。

**判断**
- 启动时快照就绪条件（端口占位符按当时的值替换）。
- 日志匹配挂在采集路径上，只做子串比较，**不得阻塞采集**（§6.1）。
- 端口检查在 `waiting` 期间至少每秒一次，复用现有原生采样辅助进程，不另起 `ps` / `lsof`；离开 `waiting` 后不再额外读取。
- 超时只标记。spawn 失败、启动观察期退出、就绪前自行结束 → `ended-before-ready`。
- 持久化；daemon 重启后，从已处理的 seq 之后续接，否则为 `unknown`。
- 就绪状态变化触发 `project.upsert`；`configChangedSinceStart` 不比较 `ready`。
- `GET /runs/:runId/ready/wait`：长轮询；任务运行 → 400。

**CLI**
- `--wait-ready [--ready-timeout]`；与 `--no-wait` 同时使用 → 用法错误（退出码 2）。
- 输出 `CliStartReport`。失败目标附阶段 3 的 `digest`；`--json` 时 stdout 始终为报告。
- 非 `--json` 时输出可读报告；未配置就绪条件时在 stderr 提示。
- 退出码优先级严格按 §13。

**mock**
- 一个按脚本输出就绪行的服务、一个按 `${port}` 就绪的服务、一个永远不就绪（短超时）的服务、一个未配置就绪条件的服务。

**原生**
- 服务状态旁显示就绪：等待中、已就绪（悬停显示用时与依据）、未就绪（琥珀色）。
- 编辑 sheet 中每个服务增加“就绪条件”分区：类型、文字列表 / 端口、等待上限。
- 运行记录显示就绪用时。
- 未就绪超时时，若窗口不在前台则通知。
- 连到旧 daemon、缺少 `ready` 时，不显示就绪标记。

**测试**
- 日志命中（含 ANSI、被 `logLineMaxBytes` 拆分的长行按单行匹配）、`sys` 行不参与匹配。
- 指定端口与任意端口；改选项值后下次按新端口判断。
- 超时不发信号；`ended-before-ready` 的各来源；daemon 重启续接与 `unknown`。
- `ready/wait` 长轮询与 400；CLI 退出码矩阵（0 / 1 / 8 / 11 / 12 与未配置）。
- 就绪后端口检查停止（用注入的采样计数验证）。

### 阶段 5：安装与分发（独立）

产品要求见 `docs/product-design-v0.4.md` §6。开源项目，**不做签名、公证、包管理器、自动更新**。

**发布包**
- 新增本地发布脚本，产出 `DevPanel-<version>.zip` 及其 SHA-256。
- 包内的 `DevPanel.app` 含管理服务（内置 Node 运行时或单文件可执行，自选，在 `docs/backend-design.md` 说明理由与体积）、原生采样辅助进程和 CLI。整体采用本机 ad-hoc 签名。
- 用户不需要另装 Node 或源码仓库。
- App 优先使用包内的管理服务与 CLI。开发场景（设置了 `DEVPANEL_HOME`）的现有行为保持不变。

**首次打开引导（可跳过）**
- 安装 CLI：链接到用户选择的目录，默认 `~/.local/bin`。显示将写入的路径，不改 shell 配置。目标已存在时显示现有内容并询问。
- 登录时启动管理服务：可选，默认关闭，沿用 `daemon install` 的语义。

**兼容**
- 读取现有数据目录 `~/Library/Application Support/DevPanel`，开发验证时用其副本。
- 写出从手工稳定版（`~/.local/share/devpanel/stable`）迁移到发布包的步骤。**不在用户机器上执行迁移。**

**根目录 README**
- 内容：定位一句话（见市场调研“DevPanel 应怎样定位”）、截图、系统要求（macOS 14+）、从 GitHub Releases 下载、首次打开放行（系统设置 → 隐私与安全性 → 仍要打开；不教用户关闭 Gatekeeper）、从源码构建、安装 CLI、给 agent 配置（skill 位置、`DEVPANEL_AGENT`）、卸载、数据目录、已知限制。
- README 中不出现个人绝对路径。
- **不添加 LICENSE**，不决定项目名称：两者都由用户决定，列入汇报。

**验证**
- 用一个不含 Node 的 `PATH`（例如 `env -i PATH=/usr/bin:/bin`）加临时 `HOME` / `DEVPANEL_HOME` 运行发布包内的管理服务与 CLI：注册示例项目、启动、看日志、停止。
- 在干净 Mac 上的完整验证列为用户手动项。

### 阶段 6：联调、验收与文档

1. 用临时 `DEVPANEL_HOME` 启动真实 daemon，用临时项目逐条验证 `docs/product-design-v0.4.md` §9。
   - 真实框架（Spring Boot / Vite）的就绪行用项目**副本**或自建的最小样例，不在用户原目录运行任何东西。
   - 用 `--snapshot` 截图。
2. 资源复测，条件与 v0.3 基线相同（`docs/plan-v0.3.md` “同条件空闲性能基线”）：
   - 空闲；
   - 服务等待就绪中 / 已就绪后；
   - 动态标签可见 / 不可见。

   确认就绪后零额外端口读取、动态不可见时零请求。
3. 更新 `skills/devpanel/`（`SKILL.md` 与 `references/`）。Claude 会 review 这部分措辞。
   - 用 `--wait-ready` 取代手动找就绪行；读日志优先 `--digest`，修改后用 `--after-seq`。
   - 接入新项目时登记就绪条件；说明在 agent 配置中设置 `DEVPANEL_AGENT`。
   - 退出码 10 / 11 / 12 的处理；用户主动停止的判断改为 `exit.requestedBy.client === 'ui'`。
   - `--override-hold` 只在用户本轮对话中明确要求时使用；删去现在已由 daemon 执行的文字规则。
4. 更新 `docs/plan-v0.4.md`（每阶段状态、提交、验收结果、截图索引、需要用户手动验证的交互清单）、`apps/mac/README.md`、`docs/backend-design.md`。
5. 不升级用户的稳定版。在汇报里给出升级步骤建议：打标签 `v0.4.0` 之后由用户执行，并说明发布包与手工稳定版如何共存或切换。

## 3. 最终汇报

1. 每个阶段的提交列表与完成情况；并行工作树的合并顺序与冲突处理。
2. 主要新增 / 修改的文件与结构；发布包的组成、体积、内置运行时的选择理由。
3. 测试结果：Swift 与 pnpm 的数量、耗时；孤儿进程检查结论。
4. 截图清单（绝对路径 + 一句说明），以及与产品文档界面条款的差异、自行决定的布局。
5. §9 逐条验收结果；资源复测数据（与 v0.3 基线对照）。
6. 需要用户亲自操作或决定的事项：
   - 手动交互清单、干净 Mac 安装验证；
   - 待决契约提案（至少包括阶段 4 列出的三条）；
   - LICENSE 与名称；
   - 升级稳定版。
7. 已知限制。
