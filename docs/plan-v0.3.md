# v0.3 开发计划（第 2 稿，已确认 2026-10-21）

> 范围：[product-design-v0.3.md](product-design-v0.3.md)（第 2 稿）。界面：[ui-design-v3.md](ui-design-v3.md)、[ui-mockup-v3.html](ui-mockup-v3.html)。契约：v1.2-C（Maven 视图与快捷操作）、v1.2-D（Git），已生效并写入 `contract/api.md` §11、§12 与 `packages/contract`。
> 前提：v0.2 已收尾（`312c0b9`）；实测 DevPanel 空闲 0.13% 单核、3 个服务运行时约 2–3% 单核。

## 已确认的决定（2026-10-21）

1. 接受契约提案 **v1.2-C**、**v1.2-D**。
2. Maven 视图 **v0.3 不做** Dependencies 树、Plugins 节点、settings.xml 编辑、Run Configurations、Gradle；需要时用“运行 Maven 目标…”手输目标。
3. 同一项目同一时刻 **只允许一个 Maven 运行**（避免并发构建互相破坏 `target/`）。
4. Git **写操作只允许界面发起**，CLI 不提供 Git 命令；**不做**丢弃改动、删除储藏、分支切换、拉取 / 推送。
5. 目录所有权：v0.3 由 Codex 实现前后端，Claude 负责设计与 review（已写入 `AGENTS.md`）。实现任务说明：`prompts/codex-v0.3.md`。

## 顺序

```
阶段 0  设计与契约提案 ──▶ 用户确认（本文件）
阶段 1  写入契约（api.md + index.ts），更新 AGENTS.md 的范围与所有权
阶段 2  通用任务运行 + 快捷操作：后端托管与 CLI ─▶ mock ─▶ 原生程序（快捷操作行与页、编辑 sheet 分区、通知）
阶段 3  Maven：pom 解析与 Maven 运行 ─▶ mock（多模块假项目）─▶ 原生程序 Maven 页（树、工具栏、命令预览、输出）
阶段 4  Git：后端 Git 模块 ─▶ mock ─▶ 原生程序（Git 摘要、改动列表、差异窗口、提交 / 储藏）
阶段 5  联调验收（product-design-v0.3 §5，用 reg-radar / cosmetic 这类真实多模块项目的副本或只读方式）、资源复测、文档；Claude review
```

阶段 2 先做通用的“任务运行”（快捷操作与 Maven 共用），阶段 3 只需在其上加 pom 解析和命令构造。Git（阶段 4）与前两者互不依赖，可以在独立工作树并行。

## 关键实现要求（摘要）

- **任务运行**：复用服务的 spawn、进程组、pid + 启动时间核验、子进程跟踪、日志与采样；新增“运行到结束”的状态机、取消 / 强制取消、超时、保留 5 次。注册不执行；不自动重跑。
- **Maven**：静态解析 pom（不运行 Maven、不联网、不读 `~/.m2`），按修改时间缓存；命令由 daemon 从结构化参数构造（`-pl`、`-am`、`-DskipTests`、`-o`、`-P`、goals），严格校验，不接受任意参数；优先 `mvnw`。
- **Git**：daemon 调用本机 git（porcelain v2、`-z`、`LC_ALL=C`、只读查询不争锁）；路径越界拒绝；写操作只接受界面客户端；HEAD 移动、钩子失败、锁冲突、储藏冲突有明确错误码；差异支持整文件上下文供并排显示；不监听文件系统。
- **界面**：检查器支持“服务或项目”；Maven 页对标 IDEA 基础部分；Git 页列表优先、差异在独立窗口；输出复用日志视图。
- **性能**：Maven / Git 页不可见时零解析、零轮询；任务结束后释放采样与日志订阅；联调时复测 DevPanel 自身 CPU / 内存。
- **测试**：任务运行覆盖并发、取消 / 强制取消、超时、选项替换、子进程无残留、daemon 重启核验；Maven 覆盖多模块解析（嵌套 `<modules>`、父 POM 在项目外、缺省 packaging、解析失败的模块）、命令构造与校验、wrapper / mvn 选择、单项目单运行；Git 用临时仓库覆盖分组解析（重命名、冲突、未跟踪、空格与中文路径）、整文件差异与截断、二进制、暂存、提交、钩子失败、锁、HEAD 移动、储藏与冲突、路径越界、非仓库、git 不存在。

## 实现与验收记录（2026-10-21）

所有实现提交位于本地 `main`，没有推送或创建发布标签。初次 A–D 实现未修改契约；下方 review 修复已按用户确认同步更新 `contract/api.md` 与 `packages/contract/src/index.ts`。旧 Web UI 仅修复必填字段兼容，未扩展功能。

| 阶段 | 状态 | 本地提交 |
| --- | --- | --- |
| A 通用任务与快捷操作 | 完成；配置/选项、运行/取消/恢复/日志/资源、CLI、mock、原生项目检查器与通知 | `2165177` |
| B Maven | 完成；静态多模块模型、缓存、结构化命令、CLI、mock、原生 Lifecycle/Profiles/工具栏/输出 | `09a62a5` |
| C Git | 完成；daemon 本地 Git、安全写操作、mock、原生列表与独立差异窗口 | `4f43348` |
| D 联调与文档 | 完成隔离联调、资源实测、截图与文档；人工交互和契约扩展单列，不替用户升级 | `b4d0ff4` |

### 检查记录

各 runner 耗时独立列出，不将并行耗时相加当作总墙钟耗时。每阶段提交前均通过 `pnpm typecheck`、`pnpm test`、`swift build`、`swift test` 和 release bundle；Swift 编译日志无 warning。

| 阶段 | pnpm 测试 | Swift 测试 | 主要日志（均在 `.devpanel-dev/codex/v03/`） |
| --- | --- | --- | --- |
| A | 154：daemon 54 / CLI 16 / mock 32 / Web 52；daemon 42.644s | 250，38 suites，2.243s | `a-final-typecheck.log`、`a-final-pnpm-test.log`、`stage-a-native-test.log`、`a-bundle.log` |
| B | 163：daemon 58 / CLI 16 / mock 37 / Web 52 | 257，39 suites，2.226s | `b-final-typecheck.log`、`b-final-test.log`、`stage-b-native-test.log`、`stage-b-bundle.log` |
| C | 180：daemon 69 / CLI 16 / mock 43 / Web 52；79.257s / 6.937s / 5.757s / 0.120s | 266，40 suites，2.234s | `c-final-typecheck.log`、`c-final-test-2.log`、`stage-c-native-test.log`、`stage-c-bundle.log` |
| D | 180：daemon 69 / CLI 16 / mock 43 / Web 52；72.079s / 2.181s / 5.495s / 0.144s | 266，40 suites，2.277s；release 23.56s | `d-typecheck.log`、`d-test.log`、`stage-d-native-test.log`、`stage-d-native-build.log`、`stage-d-bundle.log`、`stage-d-native-selfcheck.log` |

过程中保留失败证据：任务日志截断测试改为等待实际输出而不是固定 250ms；旧 early-exit 测试用 `/usr/bin/true` / `false` 验证观察期退出，避免 Node 启动在编译负载下超过测试的 200ms。没有通过扩大产品容错或跳过断言掩盖失败。

孤儿进程：已复现公共 cleanup 在 HTTP 关闭后吞掉 force-stop 失败、随后关闭 Manager 而保留 silent fixture 的漏洞；现先保存 pid+启动时间，失败兜底核验清理并等待身份消失。新增红→绿回归确认修复。历史遗留 PID 已不存在，不能声称唯一追溯到当年的具体一次测试。Git 查询另覆盖“100ms 派生 detached 子进程、父进程随后退出”的超时清理；返回时两条身份均不存在。采样仍不能保证捕获任意瞬时脱离的后代，不能核验时绝不发信号。

### 产品 §5 逐项验收

真实 Maven 验收源仅复制 `/Users/demo/Projects/cosmetic/cosmetic-java-server/jeecg-boot` 的 POM 结构至隔离目录，未在原项目执行命令。副本静态模型为 10 个模块，Profiles 为 dev/test/prod/SpringCloud；使用自行创建的模拟 mvnw，无网络/依赖下载。Git 验收使用 `.devpanel-dev/codex/v03/c/repo` 独立临时仓库。所有运行使用 `.devpanel-dev/codex/v03/a|b|c` 的隔离 home。

| 场景 | 自动/联调证据与结论 | 人工复核 |
| --- | --- | --- |
| 打开 Maven 项目 | 真实 POM 副本 10 模块/4 Profiles；静态测试覆盖嵌套、默认 jar、外部 parent、错误隔离、循环/越界与补建缓存；注册后无任务运行 | 树展开、悬停错误说明 |
| 运行阶段 | CLI + 真实 daemon 执行模拟 wrapper；`-pl jeecg-boot-base -am -DskipTests clean install`，程序实时日志，退出码0、用时1秒 | 双击 install 的触感、窗口后台通知 |
| 多选阶段 | 原生选择逻辑测试与 clean/install 高亮截图、正确排序命令预览通过 | ⌘点击/Enter/右键、clean 服务运行确认 |
| 并发 | Maven 第二请求409且含runId；动作独立槽位、同动作幂等；原生忙态测试通过 | 忙态文案与取消入口 |
| 快捷操作 | 注册不执行、当前选项替换、secret遮盖、inline、编辑/删除保护、卡片/日志截图通过 | 编辑sheet、服务运行确认、通知授权 |
| 取消 | 真实进程树测试：取消/强制取消/等待超时/执行超时；验证pid+启动时间，无已核验残留 | ⌘.、超时后强制按钮 |
| CLI | action/maven运行、follow、JSON、logs --run、成功/失败退出码通过；输出在真实程序截图可见 | 无额外前置操作 |
| Git 列表 | 临时仓库分组、中文/空格/换行、重命名、两侧状态、敏感标记、非仓库、缺git、5000条截断、ahead/behind；暂存/取消后刷新通过 | ⇧/⌘多选、Space切换 |
| 差异窗口 | 真实并排/统一/折叠/行内高亮/二进制截图；整文件/5000行/2MiB、符号链接、冲突文本测试通过；独立窗口按项目/文件/侧复用 | 重复开窗、多窗、F7/⇧F7、⌘]/⌘[、Finder、焦点刷新 |
| 提交/储藏/敏感/钩子/锁 | 临时仓库提交/amend、expectedHead与提交期间HEAD移动、钩子失败、原锁保留、stash/apply/pop和冲突保留通过；UI敏感确认规则有测试 | 真实鼠标提交确认、钩子横幅、储藏冲突提示 |
| 资源 | 可见性/失焦/后台/断连注入transport计数测试为0请求；任务结束stats.tasks清空；实际数据见下表 | 长时间日常观察 |

截图验证不替代人工交互：上述人工项需要用户在开发包与隔离数据上复核，不代表核心后端尚未实现。

### 时钟与刷新约定

v0.3 新增 `TaskRunText` / `TaskQuietText` 仅在运行且连接时为时长文字创建时钟，任务结束不挂钟；未用 TimelineView 包新列表或面板。储藏时间为静态本地绝对时间。旧界面已有时钟范围未在本次修改。

Git 使用按项目共享的刷新协调器，仅实际 viewport 可见、窗口为前台 key window、App active 且连接时启动；失焦/隐藏/后台/断连取消。每轮完成后间隔5秒，不叠加重复请求；文件计数只获取可见行，并有过期响应保护。写操作强制立即刷新；差异窗口仅获得焦点检查，未安装文件监听器。Maven仅打开标签或明确重载时获取模型，daemon缓存不后台解析。

### 资源实测

release 0.3.0 实测；每个场景独立启动界面进程，启动期前5秒不计，采样约13秒、窗口观察20秒。CPU按累计进程CPU时间差/墙钟时间计算，100%=单核；内存为RSS中位数（不是footprint）。仅计界面、隔离daemon和直属采样helper，不含构建任务或短暂Git子进程。短窗口数据用于本轮验收，不是长期负载结论，也不与v0.2不同条件的0.13%直接比较。截图启动瞬时的工具栏数值不作为稳定态测量。

| 场景 | 采样秒数 | 界面 CPU / RSS MiB | daemon CPU / RSS MiB | helper CPU / RSS MiB | Git刷新轮数（观察20秒） |
| --- | --- | --- | --- | --- | --- |
| Git 可见且前台 | 12.77 | 2.114% / 117.50 | 1.800% / 69.00 | 0.391% / 2.25 | 4 |
| Git 窗口隐藏 | 12.83 | 1.481% / 120.22 | 0.078% / 71.38 | 0.000% / 2.25 | 0 |
| Maven 运行中（前台） | 12.79 | 5.395% / 142.52 | 1.642% / 44.47 | 0.704% / 2.31 | 0 |
| Maven 结束后（前台） | 12.82 | 1.716% / 136.62 | 0.078% / 35.38 | 0.000% / 1.00 | 0 |

前台三次均记录从激活至截图结束持续 appActive=true / keyWindow=true；Git隐藏时全程不可见，0轮刷新。第一次Git可见测量中途失焦，`d-git-visible.*`仅作混合状态失败证据，未纳入表。新的验收开关只激活一次，记录焦点通知，不重复抢焦点。

Maven使用35秒模拟wrapper、每秒输出一行；运行时stats中有1个任务、2个进程，结束后`currentRun=null`、`tasks={}`、`services={}`、total unavailable，日志状态显示“已结束”。helper可保持驻留但结束后测得0 CPU，不再为已结束任务采样。Maven页没有周期模型请求，隐藏/后台Git零请求由注入transport测试和本轮真实隐藏窗口计数共同验证。

原始证据：`.devpanel-dev/codex/v03/resource-bench.py`；上述四组同名`.json` / `.log` / `.png`，`d-maven-running-stats.json`、`d-maven-ended-stats.json`、`d-maven-final-status.json`。隔离daemon与验收App在结束后清理，保留数据、日志和截图供复核。

### 截图索引与视觉差异

截图均为本地 release / debug 实际窗口渲染，没有修改用户安装。相对本文的本地证据目录为 `../.devpanel-dev/codex/v03/`（被 Git 忽略）：

| 文件 | 场景 |
| --- | --- |
| `a-actions-dark.png` | 快捷操作选择、历史与成功输出 |
| `stage-b-maven-dark.png` / `stage-b-maven-light.png` | Maven模块树、clean/install多选、完整预览与成功输出 |
| `stage-c-git-dark.png` / `stage-c-git-light.png` | 已暂存、未暂存、未跟踪三类分组、敏感标记、改动计数、储藏与提交区（本 fixture 没有冲突行，故未显示冲突分组） |
| `stage-c-diff-dark.png` | 并排差异、两处修改、行内高亮、40行未改动折叠 |
| `stage-c-diff-unified-light.png` | 统一差异与折叠 |
| `stage-c-diff-binary.png` | 二进制12→14 KiB，工具栏顶部、页脚底部 |
| `d-maven-running.png` / `d-maven-ended.png` | 最终0.3.0包：实时任务输出与35秒正常结束 |
| `d-git-visible-2.png` / `d-git-hidden-2.png` | 最终0.3.0包：资源验收窗口渲染（隐藏时也能离屏截图） |

视觉核对以设计文档和 HTML 源为依据；浏览器拒绝打开本地 file:// 视觉稿，未绕过该限制。原生系统控件的尺寸/滚动条、字体、窗口标题栏与 HTML 存在正常差别；列表优先、Maven树与输出上下分区、独立差异窗口保持设计结构。使用真实 POM 名称/路径代替稿中的虚构项目名。

### 待用户决定与已知限制

- review 已接受并落地三项契约变更：任务日志 end 载荷联合类型、Maven goal 禁止开关前缀、Git 差异 baseOid/newOid；任务 lastRun 语义也按本轮授权统一。提交钩子实时输出推迟，ui-design-v3 §5.3 明确为提交结束后显示。
- 差异版本指纹覆盖二进制与截断区外内容；焦点检查可识别内容变化。仍按设计在获得焦点时检查，不监听文件系统。
- Maven只做静态XML，不执行effective-pom、不展开完整Maven属性/继承模型、不读取外部父POM或 ~/.m2；未知/外部/解析失败模块显示原因。
- 本机ad-hoc签名开发包，未公证。系统通知授权、焦点、键盘及上表交互需用户亲自复核。
- A/B/C/D 与本轮八项 review 修复仅提交本地 main；不推送、不打发布标签、不覆盖稳定版、不更改用户 daemon。升级需用户决定并亲自执行下面步骤。

## v0.3 review 修复记录（2026-10-21）

本轮按 review 编号分别提交；每次提交前均通过 `pnpm typecheck`、`pnpm test`、`swift build`、`swift test`、`apps/mac/scripts/bundle.sh`，Swift 编译无 warning。所有 daemon / 测试 / 验收均使用隔离数据目录；未调用稳定版命令或改变其安装。

| 项 | 本地提交 | 变更与验证 |
| --- | --- | --- |
| 1 契约 | `8cc19c3` | 三项接受提案写入语义与类型并移至已生效；钩子输出延后显示。真实任务 SSE end 联合载荷、二进制/截断/符号链接 blob 指纹回归；Swift 267 项通过。 |
| 2 暂存后的差异侧 | `b555c16` | 成功后翻转 staged 并重新加载，窗口登记键同步；失败保留原视图、过期响应丢弃。新增红→绿回归；目标侧已有窗口时直接接收新内容并丢弃旧焦点响应，补充回归。初验 Swift 271 项、最终全量 277 项通过。 |
| 3 差异加载入口 | `c9fb343` | 经 AppModel / GitState 加载，视图不直接调用 client；fake transport 校验文件/侧/上下文及断连。Swift 272 项通过。 |
| 4 超时竞态 | `76f9e6a` | 身份扫描确认仍存活后才记超时；阻塞扫描时自然退出 0/7 均保留实际结果。红→绿回归；Swift 272 项通过。 |
| 5 测试清理 | `dc9d6d4` | tasks/Maven/integration 共用 finally 清理；注入 stopAllTasks 失败仍关闭 HTTP、核验身份兜底清理、删除临时目录。Git 短命父进程 fixture 用握手消除时序偶发；Swift 272 项通过。 |
| 6 界面细节 | `0933cdc` | Git 摘要三种状态及单侧箭头；Maven 根默认展开、保留其他 Lifecycle 展开、Profiles 固定树顶、未展开属性名回退 artifactId。Swift 275 项通过。 |
| 7 模块与类型 | `9b714a6` | TaskRuns 拆分、显式 action/Maven 身份、真实任务日志类型、三种 Swift 开放枚举、集中 Git 写权限、统一已结束 lastRun；同名服务/任务隔离、旧记录迁移、CLI 任务日志与 mock 回归。pnpm 187（daemon 74 / CLI 16 / mock 45 / Web 52）、Swift 276 项通过。 |
| 8 同条件性能与记录 | 本提交 | 两版 release 包、隔离 daemon 的交替空闲基线见下；Git/Maven 模块与 XML 解析器改为首次请求/解析时加载；加载跟踪通过，pnpm 187 / Swift 277 项通过；更正截图索引，并更新人工交互清单。 |

修复验证日志位于 `.devpanel-dev/codex/v03/review/`：`check-1.log` / `swift-1.log`、`check-2.log`、`check-3-retry.log`、`check-4.log`、`check-5.log`、`check-6.log`、`check-7.log`、`check-fixup.log`（277 项 Swift，含已有目标窗口回归）。第 3 项期间遇到旧 Git 短命父进程 fixture 偶发，已在第 5 项修正；第 6 项轮询测试改为先等待在途请求结算，再验证隐藏后不发起新请求。最终全量结果记录在 `check-8.log`。

### 同条件空闲性能基线

本机 Mac17,3（10 核、24 GiB）、macOS 27.0.1（26A434）、Node 24.21.0、pnpm 12.4.1。v0.2.0 从本仓库标签 `312c0b9` 用 `git archive` 导出到 `.devpanel-dev/codex/v03/review/v020`，独立安装依赖、编译 native sampler 与 release App；未读取/修改用户稳定版安装。当前版为上方第 7 项加本提交的按需加载修复。

两版使用同一 Node、正常 release App 启动方式和短路径临时 `DEVPANEL_HOME`：**零注册项目、零服务/任务运行、Git/Maven 页均不可见**。主窗口默认 1180×760，后台且不在屏幕上（`active=false / hidden=false / onscreen=false`）；这与 App 被系统标记 hidden 不同。每轮第 10/30/55 个采样点校验主窗口状态、尺寸一致（忽略系统菜单条小窗口）；有焦点或窗口状态不符的预检样本均剔除。App 副本使用同一个隔离 bundle ID，仅清空该测试 ID 的 UI 偏好，不动用户偏好。测量期间不运行构建或测试。

顺序为 `v0.2→当前`、`当前→v0.2`、`v0.2→当前`，每轮新进程和新 home；预热 10 秒后采样约 48 秒。CPU 为 `proc_pid_rusage` 累计 user+system（转换 mach timebase）增量/墙钟时间，100%=单核；RSS 与 physical footprint 为轮内中位数，下表取三轮中位数。界面、daemon、直属 sampler 分开统计，未把构建、测试或用户其他项目进程计入。

| 进程 | v0.2 CPU % | 当前 CPU % | v0.2 RSS MiB | 当前 RSS MiB | v0.2 footprint MiB | 当前 footprint MiB |
| --- | --- | --- | --- | --- | --- | --- |
| 界面 | 1.127 | 1.150 | 97.24 | 97.75 | 27.63 | 28.17 |
| daemon | 0.185 | 0.193 | 65.48 | 65.77 | 37.54 | 38.08 |
| sampler | 0.004 | 0.003 | 0.88 | 0.88 | 1.19 | 1.20 |

| 版本 / 轮次 | 采样秒数 | 界面 CPU % / RSS / footprint MiB | daemon CPU % / RSS / footprint MiB | sampler CPU % / RSS / footprint MiB |
| --- | --- | --- | --- | --- |
| v0.2.0 / 1 | 48.05 | 1.053 / 97.24 / 27.59 | 0.185 / 56.34 / 37.54 | 0.004 / 0.88 / 1.19 |
| v0.2.0 / 2 | 48.18 | 1.127 / 96.12 / 27.63 | 0.185 / 65.48 / 37.46 | 0.003 / 0.88 / 1.19 |
| v0.2.0 / 3 | 48.02 | 1.199 / 104.69 / 28.56 | 0.200 / 90.02 / 46.72 | 0.004 / 1.61 / 1.19 |
| current / 1 | 48.01 | 1.208 / 97.75 / 28.17 | 0.193 / 64.54 / 38.08 | 0.003 / 0.88 / 1.20 |
| current / 2 | 48.13 | 1.116 / 97.45 / 28.05 | 0.193 / 65.77 / 37.88 | 0.003 / 0.88 / 1.20 |
| current / 3 | 48.06 | 1.150 / 111.91 / 43.03 | 0.180 / 79.77 / 56.57 | 0.003 / 1.62 / 1.20 |

结论：在本组条件下未发现超出轮间波动的明显回退。界面 CPU 中位数 +0.023 个单核百分点、RSS +0.51 MiB、footprint +0.55 MiB；daemon CPU +0.008 个单核百分点、RSS +0.29 MiB、footprint +0.54 MiB。内存并非逐字节不增长：单轮 RSS/footprint 有明显分配与驻留波动，已保留全部轮次；不使用百分比放大小绝对差，也不将短时基线当成长时间泄漏检查。

首次预检暴露 eager XML parser 的内存成本，因此本提交将 Git/Maven 模块改为首个实际请求才 import，XML parser 改为首个 POM 解析才 require。项目概览仅检查 pom.xml 是否存在。`lazy-check.log` 的模块加载 hook 实测确认：启动、注册 Maven 项目、读取概览均未加载上述模块；首次 Maven 请求加载 Maven/XML，首次 Git 请求才加载 Git。没有为已隐藏页面建立后台解析或轮询。

原始证据在 `.devpanel-dev/codex/v03/review/`：`idle-bench.py`、`app-state.swift`、`idle-final.log`、`idle-{v0.2.0,current}-{1,2,3}.json`、`idle-summary.json`，以及 `lazy-check.log`、`daemon-build.log`。此前不同焦点/窗口条件的预检文件仅保留作排查记录，不混入正式表。该基线仅覆盖空项目列表的后台空闲；不据此声称前台 Git、Maven 构建或大量已注册项目的性能结论。原阶段 D 的资源数据继续作为对应场景的历史记录。

最终清理：六轮记录的所有界面、daemon、sampler PID+启动时间均已消失，六个临时 home 均删除；全量测试后扫描测试夹具/隔离项目进程为空，benchmark App 无残留。证据为 `final-process-audit.json`。稳定版 daemon 与 sampler 仅做只读存活核验，未向其发信号。另有 PID 4672 的开发 App 于 10:22:21 启动，早于本轮 review；不在本轮保存的进程身份中，保留且未发信号，不将它算作本轮测试残留。

### 仍需用户手动验证

请使用开发包与临时 `DEVPANEL_HOME`，沿用本轮隔离 fixture，避免将验收切到真实数据：

- 差异窗口：连续暂存/取消暂存后标题与内容切到目标侧；同文件/同侧不重复开窗，目标侧已开窗时正确复用；写失败保持原内容。F7/⇧F7、⌘]/⌘[、Space/Enter、并排/统一与焦点变化提示（含相同大小二进制、截断区外改动）。
- Maven：首次根模块展开；切换模块保留先前展开的 Lifecycle；小窗口下 Profiles 固定可见；`${...}` 名称显示 artifactId。⌘多选、双击、Enter、右键、运行前 clean 确认及忙态取消。
- Git 卡片：非仓库隐藏、干净仓库“无改动”、仅 ↑ 或 ↓ 非零的一侧显示；多选暂存、敏感文件确认、⌘↩提交、钩子结束后的输出、HEAD 移动/锁冲突提示、储藏应用冲突保留储藏。
- 快捷操作与通知：编辑 sheet、服务运行确认、⌘. 取消、超时强制按钮；系统通知权限、后台完成提醒、点击通知定位正确任务日志（包含与服务同名的 action），新运行期间历史仍能查看最近一次已结束记录。

## 用户的稳定版与升级步骤

用户日常使用的稳定版（2026-10-21 安装）：
- 代码：`~/.local/share/devpanel/stable`，git 标签 `v0.2.0`（`312c0b9`），从本仓库克隆。
- CLI：`~/.local/bin/devpanel`、`devpaneld` → 稳定版目录。
- 程序：`/Applications/DevPanel.app`（由稳定版打包）。
- 管理服务：由稳定版运行，使用真实数据目录 `~/Library/Application Support/DevPanel`；未设开机自启。

v0.3 验收通过、在本仓库打好标签 `v0.3.0` 后，由用户决定何时升级：

```bash
cd ~/.local/share/devpanel/stable
git fetch --tags && git checkout v0.3.0
pnpm install --frozen-lockfile && pnpm --filter @devpanel/daemon build:native
devpanel daemon stop --stop-services        # 会停止所有受管服务；先确认可以停
devpanel daemon start
cd apps/mac && ./scripts/bundle.sh && ditto build/DevPanel.app /Applications/DevPanel.app
```

契约 v1.2 只新增字段，已有项目配置无需修改。升级前退出 DevPanel 窗口；升级后重新打开。
