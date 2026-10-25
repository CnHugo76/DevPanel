# DevPanel macOS 原生程序

DevPanel 是本地项目运行面板。当前版本为 v0.4.1，包含服务管理、日志、启动选项、资源占用、快捷操作、Maven 工程与 Git 工具，以及就绪判断、日志摘要、操作来源和 AI 托管规则。

## 当前版本与打开方式

`apps/mac/build/DevPanel.app` 是供界面开发的 App；根目录 `pnpm release:local` 生成带 Node、CLI、daemon 的完整分发包。两种构建均不会自动安装，迁移与回退见 [发布说明](../../docs/release-v0.4.md)。开发时保留个人已安装的 App / CLI 与正在运行的 daemon，始终使用隔离数据目录。

开发验收应在终端设置独立的 `DEVPANEL_HOME`，用源码 CLI 启动独立 daemon，再运行开发 App 的可执行文件，完整命令见下文“使用隔离的真实 daemon”。直接双击开发 App 不会继承终端环境变量，可能连接真实数据目录，因此不用于本轮隔离验收。开发环境中也不要点击默认的“启动管理服务”：该入口查找用户安装的 CLI；请使用 `node packages/cli/src/main.ts daemon start`。

关闭窗口或按 ⌘Q 退出界面不会停止已运行的服务或任务。需要结束隔离环境时，先停止该环境中的运行，再停止该环境的 daemon。原生界面只是客户端；`bundle.sh` 生成的开发包需要独立 daemon，完整分发包可脱离源码仓库运行。

### 重新打包

只有原生源码更新后才需要重新打包。在仓库根目录执行：

```sh
DEVPANEL_HOME="$PWD/.devpanel-dev/mac-check" apps/mac/scripts/bundle.sh
```

需要支持 Swift 6 的 Xcode 工具链；脚本生成 release 构建并进行本机 ad-hoc 签名，产物为 `apps/mac/build/DevPanel.app`，默认版本 `0.4.1`，可用 `VERSION=0.4.2-dev` 覆盖。脚本不启动 App、daemon 或项目，不复制到 `/Applications`，也不做发行公证。

登录自启、安装 CLI、替换稳定版和复制 App 到“应用程序”均由用户在升级时选择。开发过程中不运行默认位置的 `setup:cli`、`daemon install` 或稳定版 CLI。

### 首次接入项目

空项目界面、管理服务未运行页和 DevPanel 菜单都可打开“接入第一个项目”指引；安装成功后也可直接进入。指引先只读检查 `devpanel` / `devpaneld` 是否链接到当前 App，分别展示用户选定的终端入口和 App 内置入口，再提供可复制的 PATH / 状态查询命令、skill 来源和 Agent 接入指令。完整包优先显示随包 skill 和快速开始的本地入口，源码包保留仓库链接。PATH 命令仅影响当前终端；安装器不修改 shell 配置。自选安装目录会被记住，隔离开发不写用户偏好。

复制的接入指令要求 Agent 根据真实项目文件校验并登记服务，保留用户选项、补齐就绪条件和项目规则，完成后等待明确启动要求。仅经 DevPanel 启动的服务会被托管；指引、安装入口检查与登记均不启动项目。

没有内置 CLI 的源码开发包展示源码命令及短路径隔离数据目录说明，不引导运行默认位置的 `setup:cli`。状态查询提示未运行时，在同一个终端启动隔离 daemon，并从该终端打开开发 App，以继承同一 `DEVPANEL_HOME`。

## 日常操作

### 总览、详情与日志

顶部 **总览／详情** 可切换布局（快捷键 **⌥⌘D**）：总览看多个项目及状态，选中服务后旁边显示日志；详情左侧是精简的服务列表，右侧大部分空间用于日志。两种布局共用选择、历史运行、搜索和日志视图。普通启动会记住上次使用的模式。

日志默认精简常见 Spring Boot / Logback / Log4j 前缀：保留时分秒（含毫秒）、级别、类名和完整正文，隐藏日期、PID、线程与包名前缀。工具栏“精简”可切回原文，悬停也可查看完整行；未知格式保持原样。INFO 用绿色，WARN / WARNING 用琥珀色，ERROR / FATAL / SEVERE 用红色，DEBUG / TRACE 用次级文字色；正文保留原有 ANSI 样式。搜索始终覆盖原文，命中的行显示完整前缀；复制全部或整行选区仍包含原始前缀。

日志堆栈默认保留错误标题、前五个 `at` 帧，以及每个 `Caused by` / `Suppressed` 及其后两帧，其余帧折叠。点击“▸ N 行堆栈 · 点击展开”查看该段；关闭工具栏的“折叠”可展开全部，再开启可重新收起。搜索覆盖已加载的全部原文，命中折叠内容会自动展开。复制全部日志、或复制包含折叠段的选区，会保留原文，不会只复制占位文字。

“搜索保留日志…”打开独立搜索页，按原文关键词查询所选服务或任务仍保留的日志，每页最多 50 处匹配，显示前后各 2 行。首次查询固定日志上限，后续页沿用同一范围；新日志需重新搜索。每页会标明扫描进度、是否还有未扫描内容和保留期截断，不把全部结果加入实时日志缓存。切换运行或关闭页面会取消查询并丢弃迟到响应。

运行中只有观察到就绪证据才使用绿色状态；未配置或仍等待检查时保持中性色，就绪超时保留进程状态并提示下一步。“命令与环境”可选择历史运行，对照其实际命令、目录和选项与下次启动配置。敏感值遮盖，实际环境只显示变量名，不推断未保存值是否变化。

日志工具栏“排障”可复制固定运行的命令、目录、遮盖后的选项、退出/就绪证据和日志摘要（最多 48 KiB），也可打开摘要内首个错误块的上下文。切换运行会取消未完成读取，避免复制另一轮运行的信息。错误摘要未识别到错误块时会明确提示，仍可全文搜索原文。

### 项目与选项

“编辑项目”可填写实例组与实例名称（一起填写或全部清空）。总览与检查器同时展示实例、实际目录和项目 ID；顶部搜索支持目录、ID、实例名，以及 `group:组名` / `instance:实例名` 精确筛选，⋯ 菜单可直接选择实例组。同组项目仍保留独立服务、运行、日志、端口配置和 AI 权限，不会合并或自动创建 worktree。

“动态”可直接输入工作 ID 筛选，不限于当前已加载的记录；记录上的“仅看此工作”是同一筛选入口。分页沿用筛选，切换工作或项目会丢弃旧请求。服务、运行记录、快捷操作与操作结果显示可选工作名称/ID；缺失时沿用原来源文案，已遮盖的 ID 显示提示且不能点击筛选。名称和工作标识由 CLI 调用方自报，不影响授权；原生请求不附带工作头。

文件菜单提供“导入共享配置…”与“导出共享配置…”，项目菜单也可导出。共享文档使用与 CLI 一致的 `devpanel.project` v1 格式，建议保存为仓库的 `devpanel.json`。导出移除 root、响应元数据和已标记的秘密值；根内 cwd 转为相对路径，本机绝对命令/参数/环境/选项值改为输入声明。枚举取值中的本机路径需先改为字符串选项，不静默改变选项结构。

导入先选择共享文件、本机根目录和可选本机输入文件，再点击“预览导入”；缺失输入时列出必填项，齐全后才请求校验。预览展示新建/更新、所选目录、配置版本、变更字段和用户值保护；“保存导入”只使用该次预览的配置和 revision，冲突后要求重新预览。缺失秘密不会清空已有值，本机输入不回显。导入不启动服务或任务，保存后会报告被保留的用户选项。更换文件、目录或输入会使旧预览失效。

共享文件上限 1 MiB，独立输入 JSON 上限 64 KiB，仅接受普通文件；输入目标限契约规定的标量位置。导出选择新文件名，不覆盖已有文件。仓库文件与面板通过明确的导入/导出同步，没有文件监听或自动双向同步。本机输入应独立保存并被仓库忽略。

- 添加项目：工具栏或空状态的“＋ 添加项目”；项目卡片 ⋯ 菜单可编辑、移除项目。保存配置不会启动项目。
- 点击服务行打开右侧检查器，可以看日志、选项、运行记录、命令与环境。
- 项目折叠时同时收起选项和服务表。展开后，选项按引用它的服务分行排列，组内省略名称开头重复的服务名；多服务共用和未引用的选项单独列出。长值在标签中省略显示，悬停或点击编辑可查看完整内容。
- 点击项目标题下的选项标签，或打开检查器“选项”页，调整文本、数字、开关或下拉值。默认只显示名称和值；点击 **?** 才展开说明、AI 编写信息、取值说明、引用位置，以及名称/说明编辑和删除操作。停止输入约 500ms 后自动保存，**下次启动生效，不自动重启**。
- 敏感选项不回显旧值，只能设置新值；留空不修改。选项名称和说明也可编辑。
- 配置被另一客户端修改时，会刷新配置并保留本次编辑的字段，提示明确重试；输入不合法时在控件下方显示原因。
- 添加选项后，可进入“编辑项目”用 `${key}` 引用它。删除被引用的选项会先展示写回命令/环境变量的预览；敏感值被命令引用时需先编辑命令。
- “待生效”对比当前运行实际使用的选项值与保存值。敏感值被遮盖或运行详情暂时不可用时，回退到配置变更和时间信息判断。

### 快捷操作与 Maven

Git / Maven 的主要入口位于实际服务行与服务检查器，按服务 `cwd` 匹配已登记目标的最深父目录。Java 服务显示匹配的 Maven 工程；前端不会显示其他目录的 Maven。切换服务同步切换目标与任务日志，菜单快捷键同样遵循当前服务。多个服务可共用一个仓库或 Maven 工程，不新增或执行配置。旧配置未登记 Maven 目标时，根目录服务或直接以 java / mvn / mvnw 启动的服务可使用旧的根 Maven 工程。

项目标题仍用于折叠，⋯ 菜单中的“项目详情…”默认打开快捷操作（存在时）或动态，保留选项和未关联到任何服务的工具入口。没有登记目标时仍可从项目页进入编辑配置。

- 快捷操作可在编辑项目中添加名称、ID、说明、命令、工作目录、环境变量、停止等待和最长运行时间。保存和校验不执行命令。项目卡片显示操作入口和最近结果，检查器显示列表、选中操作的输出与历史运行。操作可以运行到结束、取消，取消超时后才提供强制取消。
- Maven 的 POM 模型由 daemon 静态解析。展开模块的 Lifecycle，单击选阶段，⌘ 点击同模块的其他阶段，双击执行；跨模块选择会重置阶段。模块右键菜单提供执行入口。父 POM 位于项目外和单个模块解析失败会就地标注。
- Profiles 按“默认 → 启用 → 禁用”循环；跳过测试、离线、同时构建依赖模块（`-am`）按项目保存。普通使用会持久化，设置 `DEVPANEL_HOME` 的隔离开发和截图不写用户偏好。
- 工具栏提供重新加载 POM、运行、取消、“运行 Maven 目标…”与“存为快捷操作”。命令预览展示最终 argv；结构化请求由 daemon 构造实际 Maven 命令，界面不执行 Maven。每项目同时最多一个 Maven 运行。
- 有服务运行时，包含 `clean` 的 Maven 操作会提示可能删除正在使用的 `target/`；快捷操作可配置“有服务运行时确认”。取消不会触发完成通知。

任务输出复用日志缓存、搜索、历史切换和截断提示。任务期间可查看 CPU、内存与进程数，结束后显示固定结果和耗时。快捷操作与 Maven 完成时，只在应用窗口不在前台的情况下通知；通知点击回到对应任务输出。

### Git 改动与差异

Git 从服务行或服务详情进入，显示当前工程对应的仓库名称、路径、分支与改动。Git 标签采用列表，包含分支与 upstream、已暂存/未暂存/未跟踪/冲突分组、每文件 `+N −M`、敏感文件名提示、储藏和提交区，不内嵌差异预览。

单击选择文件，⌘ 增减选中，⇧ 连续选择；复选框和组标题按钮用于暂存/取消暂存，也可以批量操作所选项。双击、Enter 或行尾 ↗ 打开独立差异窗口。同一项目、文件、暂存侧重复打开会激活已有窗口，不同文件可以同时打开。

差异支持并排/统一、完整上下文、长未改动段折叠、行内变化高亮、改动/文件导航、暂存此文件和在 Finder 中显示。二进制显示前后大小；服务端截断时明确提示。窗口重新获得焦点时检查内容；检测到变化只提示“文件已变化 · 刷新”，保留当前阅读位置，直到用户刷新。

提交需填写信息，可选择修改上一次提交。发送时携带用户看到的 HEAD；HEAD 已移动会刷新状态并要求重新提交，不自动重试。敏感文件名会在提交前再次警告。钩子失败显示横幅并保留输出；索引锁只报告原文，不删除锁文件。储藏可以包含未跟踪文件，并可 apply 保留或 pop 恢复并移除；发生冲突会保留储藏。不提供丢弃文件、单独删除储藏、分支切换或远端操作。

Git 页或具体文件行必须实际出现在可见区域，且对应窗口在前台、应用活跃、daemon 已连接，才参与轮询。同项目共享一个循环，获得焦点刷新后每 5 秒更新；隐藏、滚出可见区域、应用后台或断连即停止。写操作结束后立即刷新。文件行计数只请求可见行的短 diff，每批最多 4 个；独立差异窗口不做定时轮询。

### 窗口、快捷键与通知

首次关闭窗口会说明后台运行行为；普通启动下记住已提示。关闭窗口后点击 Dock 可重新打开。⌘Q 只退出界面，停止全部服务并退出管理服务是另一项操作；有运行中服务时会二次确认，停止失败会如实显示原因并保留 daemon。

| 菜单 | 操作 | 快捷键 |
| --- | --- | --- |
| 文件 | 添加项目 | ⌘N |
| 文件 | 编辑 / 移除选中服务所属项目 | — |
| 项目 | Maven / Git | ⌥⌘M / ⌥⌘G |
| 项目 | 运行快捷操作 / 取消运行中的任务 | 子菜单 / — |
| 服务 | 启动 / 停止选中服务 | ⌘↩ |
| 服务 | 重启 | ⌘R |
| 服务 | 强制停止（仅停止超时后可用，需确认） | — |
| 服务 | 打开日志 | ⌘L |
| 显示 | 显示 / 隐藏检查器 | ⌥⌘I |
| 显示 | 总览 / 详情 | ⌥⌘D |
| 显示 | 搜索：日志检查器打开时搜索日志，否则搜索总览 | ⌘F |
| DevPanel | 退出界面 | ⌘Q |
| DevPanel | 接入第一个项目 / 安装 CLI 与登录启动 | — |

局部快捷键：Maven 页 Enter 运行选中阶段、⌘. 取消；Git 文件列表 Space 切换暂存、Enter 打开差异；提交信息框内 ⌘↩ 提交；差异窗口 F7 / ⇧F7 跳至下一/上一改动，⌘] / ⌘[ 打开下一/上一文件。

菜单按连接、选中和服务状态禁用；操作进行中连续按快捷键不会重复发送。空总览保留搜索框。“定位到项目”会滚动到对应卡片。查看已经结束的运行时，日志“跟随”按钮禁用。

系统通知需要通过打包后的 `.app` 运行。首次出现需要通知的事件时请求权限：自行异常退出（failed + self-exit）、daemon 丢失运行（daemon-lost）、服务状态 unknown。主动停止、强制停止、正常退出 exit(0)、启动时首个快照中的历史失败不通知。同一运行在一次客户端会话中最多通知一次，点击通知打开该服务日志。

Dock 角标显示 failed / unknown 服务数量，数量为零时清空；角标计数不依赖通知权限。

---

以下内容供开发、排查和自动化验收使用。日常使用不需要执行。

## 连接方式与开发隔离

原生程序使用 SwiftUI（macOS 14+），只是 daemon 的客户端。它读取 `<home>/daemon.json` 中的端口和 token，连接 `http://127.0.0.1:<httpPort>/api/v1`。每次重连都会重新读取发现文件，以跟随 daemon 重启。

`<home>` 默认是用户数据目录；设置 `DEVPANEL_HOME` 时使用指定目录。**测试与开发必须使用隔离目录，不要连接真实用户数据目录。** daemon 在连接后消失时，保留灰色、冻结的最后总览，并显示过期提示和启动入口。

规格见 `docs/product-design-v0.3.md` 与 `docs/ui-design-v3.md`，未被覆盖的 v0.1/v0.2 规则继续有效；接口以 `contract/api.md` 和 `packages/contract/src/index.ts` 为准。

### 构建、测试与打包

```sh
cd apps/mac
export DEVPANEL_HOME="$PWD/../../.devpanel-dev/mac-check"
swift build                   # 调试构建
swift test                    # 单元测试
scripts/bundle.sh             # release → build/DevPanel.app
# 直接运行可执行文件，明确继承开发环境变量：
build/DevPanel.app/Contents/MacOS/DevPanel
```

无需打开 Xcode 界面，也可以用 `open Package.swift` 浏览项目。

### 使用 mock daemon

mock 不执行真实项目命令，适合界面开发。从仓库根目录启动：

```sh
pnpm dev:mock                 # 写入 .devpanel-dev/mock/daemon.json
```

在另一个终端运行：

```sh
DEVPANEL_HOME="$PWD/.devpanel-dev/mock" apps/mac/build/DevPanel.app/Contents/MacOS/DevPanel
```

### 使用隔离的真实 daemon

macOS Unix socket 路径不能超过 103 字节，因此数据目录要短；`DEVPANEL_PORT=0` 让系统分配空闲端口。

```sh
export DEVPANEL_HOME=$(mktemp -d /tmp/dp.XXXXXX) DEVPANEL_PORT=0
node packages/cli/src/main.ts daemon start
apps/mac/build/DevPanel.app/Contents/MacOS/DevPanel
# 验收结束并停止该隔离环境内的项目后：
node packages/cli/src/main.ts daemon stop
```

## 无窗口自检

```sh
DEVPANEL_HOME="$PWD/.devpanel-dev/mock" apps/mac/build/DevPanel.app/Contents/MacOS/DevPanel --self-check [--timeout 10]
```

使用与窗口相同的 AppModel 连接，等待 snapshot，核对 `GET /daemon` 和 `GET /projects`，打印项目/服务数量并退出，不打开窗口。

| 退出码 | 含义 |
| --- | --- |
| 0 | 已连接，snapshot 与 REST 一致 |
| 1 | 其他失败 |
| 2 | daemon 未运行，发现文件不存在或端口没有监听 |
| 3 | 不可达，或等待 snapshot 超时 |
| 4 | token 被拒绝 |
| 5 | snapshot 与项目查询不一致 |

## 界面截图与自动化驱动

参数格式中的 `[...]` 表示可选项，`…` 表示省略相同的程序路径，不能直接当作完整命令复制。

```sh
DEVPANEL_HOME="$PWD/.devpanel-dev/mock" apps/mac/.build/debug/DevPanel --snapshot /tmp/x.png \
  [--appearance light|dark] [--size 1180x760] [--select <projectId>/<serviceId>] \
  [--perform stop:<projectId>[/<serviceId>]]... [--query <text>] [--delay <sec>] [--timeout <sec>]
```

先连接并等待 snapshot、项目配置及运行中的 stats，再执行 `--perform` 并等待操作、选中服务、等待 `--delay` 秒，最后用 `cacheDisplay` 渲染自身窗口内容并退出。窗口透明不可见，无需屏幕录制权限。退出码：0 写入成功、1 参数或文件写入错误、3 未连接。

这些驱动参数可能真实修改配置或启停服务，**只能用于 mock 或隔离验收环境**。

总览验收参数：`--collapse <projectId>` 折叠卡片；`--expand-options <projectId>` 展开该项目的选项（均可重复）；`--overview-scroll <points>` 在布局完成后滚动总览到指定偏移。后者用于检查标题栏边界，仅用于总览窗口，不与 `--layout detail` 或差异窗口组合。普通快照使用内存中的视图偏好，不写用户的展开状态。

v0.3 使用反馈调整：卡片标题整行（右侧操作按钮、Git 摘要除外）切换折叠，项目名不再打开检查器；Finder 入口保留在 ⋯ 菜单。项目详情从 Git、快捷操作、Maven 或“项目详情…”明确进入，空快捷操作的默认页为 Maven（存在时）或 Git，并纠正旧的空快捷操作页偏好。选项默认收为一行，按项目记住展开状态，待生效数量始终在摘要中用琥珀色显示。服务身份使用 3 pt 蓝／青／灰竖条，表格、选项分组、导航和日志标题共用调色板，状态仍由胶囊表示。

标题栏保留不透明 `Theme.bar` 和底部分隔线，内容区单独裁剪并置于标题栏下层。时钟仍局限于 `TimeCell` 等文案视图；选项摘要仅观察已有 `ParamPresentationStore`，不订阅原始 stats。

本轮使用反馈验收（2026-10-21）：`swift build`、`swift test`（290 项）、release bundle 均通过，编译与打包日志 0 warning；`pnpm typecheck`、`pnpm test`（192 项：daemon 79 / CLI 16 / mock 45 / Web 52）通过。新增回归覆盖选项默认收起／跨卡片与重建记忆、空快捷操作默认页／旧偏好回退，以及 stats 更新不使项目与选项摘要失效。通过隔离 mock 的原生 UI 实点确认标题折叠／展开、不打开检查器、选项展开在卡片折叠后保留、无快捷操作项目从“项目详情…”进入 Git。

快照与日志位于仓库 `.devpanel-dev/codex/v03/ui-feedback/`。`before/` 为改动前 release（只加相同的快照滚动助手），`after/` 为改动后 release，每个场景均有 `-light.png` / `-dark.png` 和对应 `.log`，共 20 张对照图：

| 文件前缀 | 检查内容 |
| --- | --- |
| `default` | 展开的卡片、改前直接展示选项／改后默认摘要、服务身份标记 |
| `card-collapsed` | 首个卡片折叠，右侧操作独立 |
| `options-expanded` | 按服务展开选项、共享组选项仅出现一次、待生效琥珀色 |
| `toolbar-scrolled` | 总览实际滚动 115 pt，内容截止于工具栏下缘，工具栏与分隔线保持不透明 |
| `service-logs` | 前端服务选中，日志标题与服务表身份竖条颜色一致 |

最终开发包为 `after/DevPanel.app`。UI 实点副本 `interactive/DevPanel.app` 使用独立 bundle ID 和固定测试 `DEVPANEL_HOME`。一次 UI 工具重开普通开发包时丢失环境变量，短暂连到真实 daemon；没有点击任何服务操作，随即按 PID+启动时间关闭该开发包并切换到隔离副本。未修改稳定版安装或向用户 daemon 发信号。

滚动前后的标题栏 52 pt 区域逐像素比较，light / dark 差异均为 0（`toolbar-pixels.log`）。CPU 使用同一 mock（6 项目、8 服务、3 个模拟运行服务）、同尺寸 1180×760 的 release 包，以 `proc_pid_rusage` 的 user+system 累计差值除墙钟计算，100%=一个核；预热 6 秒后每轮测量约 12 秒，顺序改前→改后、改后→改前，两轮均值。测量期间无并行构建或测试，改后“全部展开”包含所有有选项的项目。

| 隐藏窗口条件 | 改前 CPU | 改后 CPU | 改前 footprint MiB | 改后 footprint MiB |
| --- | --- | --- | --- | --- |
| 默认展开状态（改后选项默认收起） | 1.064% | 0.939% | 50.68 | 46.35 |
| 所有选项展开 | 1.087% | 1.062% | 50.06 | 49.71 |

本组隐藏窗口条件未发现 CPU 回退。原始数据、PID+启动时间、焦点事件与采样脚本在 `cpu-hidden-*.json` / `.log`、`cpu-hidden.py`，汇总为 `cpu-hidden-summary.json`。普通 bundle 和独立 bundle ID 的前台测量均发生失焦，分别保留在 `cpu-*.json` / `.log`、`cpu-isolated-*.json` / `.log`，不将其汇总用于性能结论；本轮无法确认持续前台的 CPU 数值。性能判断同时参考时钟与 stats 观察边界未扩大、对应隔离回归通过，不把隐藏窗口结果外推到所有场景。

### 检查器和日志参数

以下通常配合 `--select`：

| 参数 | 作用 |
| --- | --- |
| `--tab logs|options|runs|cmd` | 选择检查器标签 |
| `--log-run <n>` | 选择按新到旧排列的运行；n ≥ 1 显示历史运行提示 |
| `--log-search <text>` | 填写日志搜索内容 |
| `--log-scroll-up <points>` | 向上滚动并暂停跟随，等待期间新增日志显示“↓ N 条新日志” |
| `--log-bench <text>` | 输出内存行数、占用以及搜索/重建/高亮/滚动耗时 |
| `--second <png> --second-delay <sec>` | 同一进程等待后再截图一次 |

10 万行检查：启动截图并指定 `--delay 25 --log-bench orders`，几秒后执行 `pnpm --filter @devpanel/mock-daemon ctl flood "" 100000`。

### v0.3 项目、Maven 与 Git 参数

以下参数只设置查看状态或草稿，不自动运行 Maven 或提交 Git。实际运行由 UI 或隔离环境的源码 CLI 明确触发。

| 参数 | 作用 |
| --- | --- |
| `--select-project <id> --project-tab actions\|maven\|git\|options` | 打开项目检查器 |
| `--action <actionId>` | 选择快捷操作及其输出 |
| `--maven-module <moduleId> --maven-goals 'clean install'` | 选择模块和阶段 |
| `--maven-profiles 'dev,!test'` | 设置 Profiles 三态 |
| `--maven-skip-tests --maven-offline --maven-also-make` | 设置 Maven 开关 |
| `--git-message <text>` | 填写提交草稿 |
| `--git-diff <path> [--git-staged]` | 改为截取该文件的独立差异窗口 |
| `--git-unified --git-expand-all` | 统一差异 / 展开所有未改动段 |
| `--bench-visible` | `--delay` 前显示并激活真实窗口，供前台资源测量 |
| `--bench-hidden` | `--delay` 前隐藏窗口和应用，供后台资源测量 |

例如，连接已经启动的隔离 Git 验收 daemon（替换项目 ID）：

```sh
DEVPANEL_HOME="$PWD/.devpanel-dev/codex/v03/c" apps/mac/build/DevPanel.app/Contents/MacOS/DevPanel \
  --snapshot "$PWD/.devpanel-dev/codex/v03/git-diff.png" \
  --select-project <id> --project-tab git --git-diff src/App.ts --appearance dark
```

`--bench-visible` / `--bench-hidden` 仅改变截图验收流程，不影响正常启动。visible 验收使用普通应用的 regular 激活策略，只主动激活一次；通知观察器记录 `bench-focus` 的单调 uptime、相对秒数及焦点变化，不用定时器反复抢焦点。结束会输出 `git-poll-refreshes` 及实际 `appActive` / `keyWindow` / `visible`；可见窗口被其他应用抢走焦点时应按真实状态解释测量结果，不把“设置了 visible 参数”当作整个区间都在前台。普通透明截图不用于证明前台轮询或 CPU 占用。

### 项目编辑参数

```sh
… --snapshot /tmp/e.png --open-editor new|<projectId> [--editor-set s0.command='pnpm dev &']... \
  [--editor-expand env|s<N>|s<N>.advanced]... [--editor-scroll top|bottom|s<N>] \
  [--editor-bump] [--editor-save]
… --snapshot /tmp/r.png --remove-project <projectId> [--confirm-remove]
```

`--editor-set` 支持：`name`、`root`、`env.<NAME>`、`s<N>.name|id|cwd|command|shell|stop`、`s<N>.env.<NAME>`、`s<N>.secret.<NAME>`。填写后执行校验。

`--editor-bump` 先通过另一请求把停止等待时间加 1，使随后的 `--editor-save` 遇到 revision 冲突。`--toast <text>` 显示结果提示。`--confirm-remove` 才真正移除登记。

### 选项和程序行为参数

```sh
… --snapshot /tmp/option.png --option <projectId>/<key> \
  [--option-value <text>] [--option-bump] [--option-save] [--option-close]
… --snapshot /tmp/add.png --add-option <projectId>
… --snapshot /tmp/delete.png --delete-option <projectId>/<key> [--confirm-delete]
… --snapshot /tmp/app.png --app-dialog firstClose|shutdown
… --snapshot /tmp/notice.png --notification-open <projectId>/<serviceId>
```

- `--option-value` 仅填写并校验；`--option-save` 执行保存；`--option-close` 关闭编辑框以展示待生效标签。
- `--option-bump` 先通过另一请求修改名称，复现 revision 冲突。
- `--confirm-delete` 执行选项删除/写回；只传 `--delete-option` 展示预览。
- `--shutdown-daemon` 执行生产代码的关闭方法；`--start-daemon` 使用正常启动器；`--launch-cli <path>` 使用指定临时 CLI 入口。
- `--before-actions-delay <seconds>` 在连接后、执行操作前等待，用于复现操作竞态。
- `--report-state <json>` 输出截图时的连接状态、项目、资源、运行详情、当前查看运行、日志行数及角标数量，不包含发现文件 token。
- `--notification-open` 调用通知点击处理器，不能证明系统实际投递成功。
- `--app-dialog` 渲染原生提示框的内联等价内容。

`--app-smoke <report.txt>` 不与 `--snapshot` 同用，且要求设置 `DEVPANEL_HOME`。它打开真实窗口，刷新 NSMenu 并记录有/无选中服务时的快捷键和禁用状态，执行首次关闭/重开，记录角标和运行身份，然后退出。不启动或停止项目服务。

开发环境不保存用户个人界面偏好，因此在设置 `DEVPANEL_HOME` 的情况下，每次启动都会重新出现首次关窗提示。

### 断连截图与视觉差异

用 `--delay 6` 启动截图，约 4 秒后执行 `pnpm --filter @devpanel/mock-daemon ctl disconnect 20`。

snapshot 不显示 hover 高亮，也无法渲染系统模糊和饱和度滤镜；需要出现在截图中的状态使用显式颜色。真实 sheet 是独立窗口，因此截图中使用居中的内联等价界面，实际 App 的 popover 会锚定触发位置。

## 重跑真实 daemon 验收

先打包，再从仓库根目录执行：

```sh
mkdir -p .devpanel-dev/codex
python3 apps/mac/scripts/acceptance.py > .devpanel-dev/codex/c-acceptance.log 2>&1
```

脚本使用 `listening`、`tree-ignore`、`exit-on-file` 测试服务，临时 CLI 入口放在 `codex/bin`，数据放在 `codex/acc`。当前检出路径的 socket 长度为 77 字节，其他检出位置也必须满足 103 字节限制。

如果 `codex/acc` 已存在，脚本会拒绝运行；先检查上次结果、停止该隔离 daemon，再清理它的数据目录后重跑。不要替换成个人数据目录。

脚本最终会停止自己隔离环境中的服务和 daemon；直接启动的 App 进程只有在 PID、启动时间、命令行都与启动记录一致时才会收到信号。证据和数据保留供检查。`--measure-only` 使用前一轮配置与结果，在新的 `codex/perf` 目录重复真实主窗口资源采样。

该脚本保留 v0.2 服务验收；v0.3 的隔离项目、逐项结果、截图、资源复测与待人工确认事项见 [v0.3 验收报告](../../docs/plan-v0.3.md)，历史服务验收见 [v0.2 报告](../../docs/plan-v0.2.md)。系统权限、通知实际点击、目录选择、键盘和焦点交互仍需人工验收。

## 代码结构

```text
Package.swift                 Swift 6，无第三方依赖
Sources/DevPanelKit/          逻辑库，不含 SwiftUI 视图
  Contract/                   契约 Codable 类型，未知枚举值 → .other
  Client/                     daemon.json 发现、URLSession、SSE、HTTPTransport、DaemonLauncher
  State/                      AppModel、项目/服务选择、任务/Maven/Git 状态、Git 可见性轮询与差异投影
  Logs/                       ANSI、5 万行缓存上限、分页与流、runId/代次核对、搜索
  Editor/                     项目表单、shell argv 拆分、后台命令检测、配置转换和校验
  Options/                    选项校验、设置者、引用预览、自动保存与冲突恢复
  Presentation/               状态文案、资源/时长格式、端口/选项标签、布局及命令预览
Sources/DevPanel/             App 入口、主窗口、自检和截图
  Overview/                   标题栏、项目卡片、服务表、检查器容器
  Inspector/                  项目/服务检查器、快捷操作、任务输出、日志（TextKit 2）、运行记录
  Maven/                      模块/Lifecycle/Profiles 树、运行/保存 sheet、命令预览、截图驱动
  Git/                        改动列表、储藏/提交、可见区域 AppKit 桥、独立差异 NSWindow
  Shared/                     强制停止确认
  Editor/                     项目编辑/移除 sheet、提示、截图驱动
  Options/                    共用控件、选项 popover、检查器、增删 sheet、截图驱动
  App/                        程序控制器、菜单、窗口桥接、系统通知、快照与真实窗口检查
Tests/DevPanelKitTests/       Swift Testing
  Fixtures/recorded/          mock-daemon v1.1 录制响应
  Fixtures/recorded-real/     隔离真实 daemon 录制响应
  Fixtures/handwritten/       按契约补充的边界样本
scripts/bundle.sh             release → build/DevPanel.app，本机签名
scripts/make-icon.swift       打包时生成占位图标
scripts/acceptance.py         真实 daemon 与 release App 隔离验收
```

## 实现约定

- 视图读取 AppModel 并调用其方法；独立差异窗口控制器通过同一个 DaemonClient 读取差异，不从磁盘猜测仓库状态。`AppModel.Environment` 可注入发现、客户端、sleep、时钟和启动器，供测试使用。
- 契约枚举允许 `.other(String)`，switch 必须覆盖未知值。契约变化时同步 `Contract/*` 和录制样本，参考 `TestSupport.swift`。
- `EditorPresenter` 管理项目 sheet 和提示；`ProjectEditor` 持有草稿并调用 AppModel。编辑保留 params，敏感值未填写时发送 `{secret:true}`，失焦时校验。`ProjectDraft(config:).build(.save).config` 的往返转换有测试。
- `model.inspector` 持有标签、运行选择、运行列表/详情、日志与搜索。常用入口：`openLogs`、`showRunLog`、`chooseRun`、`viewedRunId`、`runs`、`refreshRuns`、`loadRunDetail`。
- `inspectorSelection` 是服务/项目的统一选择；服务侧保留 `selection` 兼容入口。快捷操作和 Maven 的日志投影分别使用 `action:<id>`、`maven:`，避免与用户服务 ID 冲突。
- `ProjectInspectorState`、`MavenState`、`GitState` 分别管理项目选择/任务、结构化 Maven 参数和仓库状态。`GitDiffLayout` 负责行配对、上下文折叠、变化块导航与 Unicode 字符级高亮；`GitDiffWindowManager` 按项目/文件/侧去重窗口。
- `GitRefreshCoordinator` 合并可见页面、摘要与文件行的租约，只为符合前台条件的项目创建可取消循环；`GitVisibility` 使用 NSView 的裁剪区域和窗口/应用通知，不增加几何轮询定时器。状态和短 diff 请求用代次校验，防止写后旧请求覆盖新状态。
- “选项”页使用 `OptionsTab`；“命令与环境”的编辑入口打开项目编辑器。
- 所有按当前时间计算的文案在断连后使用 `model.displayNow(date)` 冻结。v0.3 新增时钟只包住实际依赖 now 的 Text，不能包住列表、行容器或面板；无运行、等待或重连状态时不创建时钟。`TaskRunText` 和 `TaskQuietText` 仅在任务运行且已连接时计时，任务完成后显示静态文本。旧服务 UI 的时钟行为未在本轮扩大修改。Git 日期为静态的本地绝对时间。

### v0.3 验证与待人工检查

阶段 C 最后一轮 Swift Testing 为 **266 项 / 40 suites，2.234 秒，全通过，零编译警告**；release bundle、签名验证与真实隔离 daemon 的 `--self-check` 通过。最终阶段 D 的重跑结果以 [计划](../../docs/plan-v0.3.md) 为准。测试覆盖任务日志投影与通知、Maven 模块/阶段/Profiles/确认、Git 分组/多选、HEAD 与敏感确认、Unicode 行内差异/上下文折叠、UI 写请求头、可见性调度与隐藏/后台/断连零 Git 请求。

截图覆盖真实 POM 结构副本的 Maven 深浅色、Git 列表深浅色、并排/统一差异、二进制大小提示。系统对话框、真实菜单焦点和输入事件仍需在隔离环境人工确认：

- 快捷操作和 Maven 的历史切换、运行/取消/取消超时后的强制取消；后台完成通知的权限、投递与点击导航。
- Maven 双击运行、⌘ 多选同模块阶段、跨模块重置、Profiles 三态、clean 确认与忙时禁用；普通启动的偏好持久化只在用户确认升级后测试。
- Git ⇧/⌘ 多选、Space/Enter、提交信息框的 ⌘↩、敏感文件确认；冲突、索引锁、HEAD 移动和钩子失败后的草稿/输出保留。
- 独立差异窗口的重复打开去重、多窗口、F7/⇧F7、⌘]/⌘[、折叠与展开、文件变化后的刷新提示；滚动到不可见区域、切换标签、隐藏/切换应用时停止轮询。
- Finder 定位、窗口缩放、深浅色、目录选择和实际 sheet/popover 定位。截图不代替这些系统交互。

### 冻结契约下的限制

详见 [待决提案](../../contract/CHANGES.md)，本轮未修改冻结的 API 文档和共享类型：

1. 任务日志流的 end 仍为服务 RunSummary，因此使用任务到服务运行的投影；真实任务终态来自 `project.upsert` / `/task-runs/:runId`。
2. Maven goals 现有正则允许以 `-` 开头的字符串，但这会被 Maven 当作开关；为维持结构化命令约束，本版拒绝此类 goal。
3. Git 提交接口只有完成后的 output，没有输出流；提交期间显示进行中，结束后显示输出及钩子失败横幅，暂不实时显示钩子输出。
4. GitDiff 没有文件版本指纹。焦点检查可识别返回文本的变化，但不能可靠识别同大小二进制或仅发生在截断区之外的变化。

### 详情模式的快照验收参数

- `--layout detail`：日志为主的详情布局；省略时为总览。
- `--collapse <projectId>`：折叠指定项目，可重复，用于验收选项与服务表一起收起。
- `--option-details`：展开选项说明，便于验收；正常启动默认收起。
- `--log-expand-all`：显示所有堆栈原文。
- `--log-expand-first`：通过文本视图的点击代理展开第一个折叠段。
- `--log-full-prefix`：关闭默认前缀精简；`--tab git|maven --select <project>/<service>` 验证工程工具归属。
- `--verify-folding`：输出折叠数量、复制原文一致性、搜索命中是否可见。
- `--verify-layout-switch`：往返切换布局，核对日志视图实例、服务、运行和搜索是否保留。

折叠实现参考 IntelliJ IDEA 的 [ConsoleFolding](https://github.com/JetBrains/intellij-community/blob/master/platform/consoleView/src/com/intellij/execution/ConsoleFolding.java) 与 [ConsoleViewImpl](https://github.com/JetBrains/intellij-community/blob/master/platform/consoleView/impl/src/com/intellij/execution/impl/ConsoleViewImpl.kt) 的“识别连续行 → 折叠区域 → 占位摘要”机制。Swift 端使用独立的 `LogFolding` 投影保留原始缓冲区，由现有 TextKit 2 文本视图显示与展开，没有移植 Java/Kotlin 控件。当前不合并重复错误，也不自动折叠任意多行文本。

### 内存统计与采样（2026-10-21）

macOS 主界面的“内存”优先显示受管进程的 physical footprint 合计，采用活动监视器的指标口径，包含系统计入该进程的压缩及换出内存。一个服务可能含多个进程，应与活动监视器中对应 PID 的合计比较。悬停可查看说明及 RSS 辅助数值。

旧 daemon 或原生查询不可用时，界面明确显示 `… MiB RSS`；未知值仍为“采样中/不可用”，不会填 0。资源默认每 2 秒更新一次，所有窗口复用同一份采样。daemon 复用一个轻量原生 helper 发现进程，不再每 250ms 启动一次全机 `ps`。

源码运行会在首次需要时检查并构建 `packages/daemon/native/build/process-sampler`（需要 Xcode Command Line Tools）；`pnpm --filter @devpanel/daemon build` 也会预先构建。没有编译工具或 helper 故障时仍可管理服务，退回较低频率的 `ps` 和明确标注的 RSS。应用和 daemon 均更新后才会使用新口径；仅重新打开界面不会替换已运行的旧 daemon。

### DevPanel 自身资源占用

窗口底部固定显示 **DevPanel 自身 · CPU … · 内存 …**。点击底栏可查看界面、管理进程、辅助进程及完整合计；这些数字不包含被管理的业务项目。CPU 的 100% 表示一个逻辑核心满载，内存优先采用 macOS footprint；所有分项都有 RSS 时才允许以 RSS 回退合计，不混用两种口径。

界面本进程通过系统 API 采样，后台数字通过 `GET /daemon` 读取已有缓存，每 2 秒更新一次，多个窗口不会创建多份采样循环。旧管理服务不支持辅助进程统计、断连、采样失败或数据超过 6 秒未更新时，底栏明确标记部分不可用或过期；仍可在明细查看已知分项，不以 0 补齐合计。

隔离开发环境截图时，追加 `--tool-resources-details` 可将同一个明细面板展开在底栏上方；例如：

```sh
DEVPANEL_HOME=/tmp/devpanel-tool-resources-test apps/mac/.build/debug/DevPanel \
  --snapshot /tmp/devpanel-tool-resources.png --appearance dark --delay 3 \
  --tool-resources-details
```

### v0.4 安装与分发

完整 App 通过根目录 `pnpm release:local` 生成，内置 Node、daemon、CLI 和采样器；`bundle.sh` 仍是界面开发包。无 DEVPANEL_HOME 时 App 优先使用内置 CLI；隔离开发保留原入口行为，不使用默认入口启动日常 daemon。

首次设置及 DevPanel 菜单中的“安装 CLI 与登录启动…”打开同一个独立 sheet。CLI 目录可选且先展示完整写入路径，已有文件/链接先展示现有内容并明确确认；预览后目标变化会拒绝写入。登录启动默认关闭，沿用 daemon install。开发隔离下默认 CLI 目录为临时 DEVPANEL_HOME/bin，不写用户 ~/.local/bin；`--snapshot … --installation` 仅展示引导。发布、迁移、回退与人工项见 [发布说明](../../docs/release-v0.4.md) 和 [验收记录](../../docs/plan-v0.4.md)。

### v0.4 来源、就绪与托管规则

服务行、检查器和运行记录显示启动/停止方；旧 daemon 缺失来源时显示“未知”。服务状态旁补充一次性就绪结果，等待/已就绪/琥珀色未就绪与进程状态分开；悬停查看用时和日志行或端口依据。编辑项目时每个服务卡片有“就绪条件”，支持日志文字、端口或 number 选项引用、等待上限；只保存配置，不执行命令。超时通知仅在窗口不在前台时发送。

项目检查器增加“动态”标签，新到旧、按工作筛选并分批加载，配置差异可展开，运行可跳到日志。仅标签可见时读取，通过 operation/project.upsert 合并刷新，不轮询。项目 ⋯ 菜单打开独立“AI 权限”sheet，保存走 policy 路由，与项目配置分开。暂停服务显示“AI 需你同意”和“允许 AI 启动”，锁定可用行右键菜单切换；规则由 daemon 执行。

日志工具栏“复制摘要”请求当前查看运行，按共享 golden 格式复制并显示轻提示。堆栈折叠保留标题、前五个 at 帧、每个 Caused by/Suppressed 及后两帧；搜索和复制原文仍基于完整原文。摘要不替代原始日志，也不做诊断。

隔离快照可追加 `--activity-expand`、`--policy-project <id>`；编辑分区沿用 `--open-editor` / `--editor-*`。资源验收的 `--bench-background` 仅在设置 DEVPANEL_HOME 时把保留的窗口置于后台不可见状态，不断开管理连接；与 v0.3 基线一致，不作为产品功能入口。
