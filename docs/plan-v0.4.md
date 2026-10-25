# v0.4 实现与验收记录

任务依据：[任务说明](../prompts/codex-v0.4.md)、[产品设计](product-design-v0.4.md)、冻结契约 v1.3-A～D。仅提交本地 main，不推送、不创建标签或 Release。所有开发和验收使用临时 DEVPANEL_HOME，不修改用户的稳定 App、CLI、数据和 daemon。

## 实现进度

| 阶段 | 状态 | 提交与说明 |
| --- | --- | --- |
| 1 操作来源与动态 | 已完成 | `b1e1e60`（工作树 `e1d9b49`） |
| 2 托管规则 | 已完成 | `cc3e2bb`（工作树 `8f04a51`） |
| 3 日志摘要 | 已完成 | `45a5653`（工作树 `f55dd5a`） |
| 4 就绪 | 已完成 | `fc3692b`（工作树 `015623a`） |
| 5 安装与分发 | 已完成 | `dddc789`；独立工作先合入 main |
| 6 联调与文档 | 自动验收完成，人工项另列 | 本文件所在的阶段 6 提交；最终数据见下文 |

## 阶段 5：安装与分发

新增 scripts/release.mjs，按本机架构下载固定的 Node 官方 24.21.0 发行包，核验官方 SHA-256，内置 daemon、CLI、共享类型、生产依赖、原生采样器。选择独立运行时是为了避免 Homebrew Node 的 Cellar/opt 动态库依赖；Node 原生运行 TypeScript，不要求用户装 Node、pnpm、Xcode 或保留仓库。内嵌 Mach-O 和 App 依次 ad-hoc 签名，生成 ZIP 与 SHA-256，不做开发者签名、公证或联网发布。

App 无 DEVPANEL_HOME 时优先使用包内 CLI；隔离开发维持原启动器行为。首次引导采用沿用 Theme 的独立 sheet，可跳过；CLI 默认安装目录为 ~/.local/bin，开发隔离时默认临时 home/bin。先显示两处目标路径，已有文件展示前 4096 字节或链接目标，确认后才原子替换；预览后目标变化则拒绝。登录启动默认关闭，仅明确勾选后调用已有 daemon install。

本阶段产物：`.devpanel-dev/codex/v04/release/DevPanel.app`（约 131 MiB）、`DevPanel-0.4.0.zip`（约 42 MiB）及 `.sha256`。这是仅安装阶段的中间包，最终功能合并后重新打包，最终校验值在阶段 6 记录。

验证：pnpm typecheck 通过；pnpm test 共 192 项通过（daemon 79 / CLI 16 / mock 45 / Web 52，daemon 86.876 秒、CLI 1.262 秒、mock 5.834 秒、Web 0.094 秒）；Swift build/test 292 项 / 44 suites，1.196 秒通过；release bundle 与签名核验通过，零编译 warning。新增 Swift 覆盖包内 CLI 优先、开发回退、覆盖确认、预览变化拒绝。

scripts/release-smoke.mjs 将 App 复制到仓库之外的含中文、空格目录，PATH=/usr/bin:/bin，临时 HOME/DEVPANEL_HOME，完成包内 daemon 启动、含 secret 环境与选项的注册、服务启动、业务日志读取、状态、停止、删除和 daemon 关闭。输出无敏感值；保存本轮 PID+启动时间，结束后复核全部消失。证据：`.devpanel-dev/codex/v04/stage5-{typecheck-final,test-final,swift-build-final,swift-test,release,smoke}.log`。

截图（均为隔离开发环境）：`.devpanel-dev/codex/v04/installation-dark.png`、`installation-light.png`。安装路径清楚、登录选项默认关闭；只展示不执行安装。README 暂用深色引导截图，阶段 6 更新完整总览截图。

根 README 补齐下载、放行、构建、Agent 配置、CLI、卸载、数据与限制；[迁移说明](release-v0.4.md) 给出手工稳定版与发布包共存、切换和回退步骤。没有执行迁移。

## 人工与待决定事项

- 干净 Mac 无 Node/源码时的完整安装、Gatekeeper 放行、终端 PATH、覆盖确认、登录项、卸载；系统通知权限与点击导航。
- 公开名称、LICENSE、v0.4.0 标签与发布由用户决定。
- 稳定版升级由用户择时执行，开发阶段不升级。
- 功能线的待决契约澄清与最终逐条验收结果将在阶段 6 汇总。

## 阶段 1、3 合并记录

监督线分支 codex/v04-supervision 与 AI 闭环线 codex/v04-ai 在忽略目录的临时工作树独立实现。main 按阶段 5 → 1 → 3 合入；阶段 3 的冲突只在 CLI 参数声明和 mock 顶部 import，均保留两边功能，没有改变冻结契约。阶段 1 自动合并了 storage 的版本号与动态保留上限。

阶段 3 整合后 typecheck、Swift 296 项 / 47 suites（1.189 秒）、release bundle（34.18 秒）通过，零编译 warning。pnpm 最终 203 项通过（daemon 88 / CLI 17 / mock 46 / Web 52）；daemon 90.038 秒、CLI 0.912 秒、mock 6.213 秒。首次全量 Git timeout 夹具未记录身份而失败，原样完整复跑通过；尚未归因，未据此声称已修复。原始结果为 merge3-test.log 与 merge3-test-final.log；其余门槛见 merge3-{typecheck,swift-build,swift-test,bundle}.log。

## 两条功能线的实现与合并

最终合入顺序为 **5 → 1 → 3 → 4 → 2 → 6**，各阶段保留独立提交。阶段 4 的冲突涉及运行记录、Swift 运行类型、manager 和 mock 种子/引擎：逐处同时保留 startedBy/requestedBy 与 ready，初始化、编码和 summary 投影一致；种子同时保留来源与就绪样例。阶段 2 在此基础上自动合并，未覆盖任一功能。未修改冻结的 contract/api.md 与 packages/contract/src/index.ts。临时工作树原始报告见 [监督线](plan-v0.4-supervision.md)、[AI 闭环线](plan-v0.4-ai.md)，关键证据已复制回主工作区。两处工作树在确认干净并归档遗留夹具源码后已删除；本地功能分支保留，不推送。

阶段 1 新增 activity.ts，覆盖请求头校验、服务/任务发起方与取消方、daemon 来源、旧记录 null、持久化。动态按终态和配置保存生成，复用 ConfigDiffEntry，敏感项遮盖、100 条截断、每项目 500 条、分页与删除；CLI activity/--agent，原生动态标签、来源显示，mock 五类来源。原阶段门槛为 pnpm 197 项、Swift 293 项，均通过，零警告。

阶段 2 新增 policy.ts，独立保存规则与暂停，ui 专属写入。入队前和执行前检查，拒绝 stop 不参与停止优先；默认暂停与强停 deny，锁定优先于 overrideHold；成功越过、配置删除服务清理锁/暂停均有动态。CLI policy/状态和退出码 12，原生独立 AI 权限 sheet、行内允许按钮/锁定菜单。原阶段 pnpm 205 项、Swift 295 项通过，零警告。

阶段 3 新增 digest.ts 与 CLI/Swift 文本格式化，test-fixtures/digest 为唯一共享 golden；有界逐行计算、同错签名去重、Java/Python 堆栈折叠、截行与预算、省略/增量。原生复制摘要和折叠保持原文搜索/复制。32 MiB 实测 **33,552,103 bytes、8,054 行，6.36ms**，blocks 1,173 bytes；包含保留上限截断，不含采集耗时。证据 ai-evidence/digest-32m-benchmark.json。

阶段 4 新增 ready.ts、ready-report.ts，校验/引用/inline、启动快照、日志与端口就绪、等待路由和报告退出码。端口复用原生 sampler；注入计数测试证明就绪后不再额外读取。日志采集器修正为仅保留可能续接 secret 的后缀，消除最后一行 READY 延迟；跨 write/newline/长行脱敏回归通过。旧管道不能接回时等待运行恢复 unknown，已就绪保持。Swift 服务行/检查器、运行记录、编辑分区和后台超时通知同步。阶段 4 合并后 pnpm 210 项（94/18/46/52）、Swift 299 项 / 48 suites、1.206 秒、bundle 30.45 秒通过，零警告。

## 阶段 6：真实联调与完整门槛

使用真实隔离 daemon（127.0.0.1 随机端口）、源码 CLI 与临时项目；Spring Boot 2.6.6 / Spring 5.3.18 由本机只读 Maven 缓存复制到忽略目录，离线编译最小 BootFixture（非 Web 应用，用 latch 常驻，仅验真实框架就绪行）；Vite 8.3.4 使用本仓库已有依赖与独立 index.html。没有在用户原项目运行命令，也没有访问网络。真实配置同时带 secret 环境变量和 secret 选项，每次响应与 CLI stdout/stderr 均断言无明文。

完整 TypeScript 门槛：pnpm typecheck 通过；pnpm test **218 项**（daemon 99 / CLI 19 / mock 48 / Web 52），耗时分别 **97.790 / 1.325 / 4.157 / 0.112 秒**。Swift **301 项 / 49 suites、1.215 秒**通过；最终 build **3.41 秒**、bundle **27.39 秒**。所有编译日志 warning/error 为 0，git diff --check 通过。没有为文档修改额外添加镜像实现的测试。

截图复核修正了窄日志工具栏的“复制摘要”文字被压缩问题，按钮保持完整宽度；就绪等待上限增加常驻秒数标签，避免填入数字后失去单位。沿用现有 Theme、系统字体、检查器与 sheet，不新增产品页面。隔离资源验收入口补充 --bench-background，保留正常 scene/连接但将窗口置于 offscreen，只有设置 DEVPANEL_HOME 时生效。预检 onscreen=true 的样本已剔除并留证。

### 产品 §9 逐条验收

| 场景 | 结果与证据 |
| --- | --- |
| 日志就绪 | 通过：真实 Spring Boot restart --wait-ready 返回 0，453ms、seq=13，界面已就绪；acceptance-result.json |
| 端口就绪 | 通过：真实 Vite 在 53972 监听，改选项后下次按 53973 就绪；没有端口碰撞时的降级启动 |
| 就绪失败 | 通过：独立编译错误夹具退出 1，首错误块为实际 stderr 编译错误；超时退出 11，status 仍 running |
| 未配置就绪 | 通过：退出 0、not-configured，stderr 明确提示 |
| 管理服务重启 | 部分满足：已就绪保持；等待运行因 §8 不能接回旧管道为 unknown，按契约允许分支处理，未声称续接成功 |
| 摘要 | 通过：50 次去重、Caused by/折叠、1024 预算标省略；afterSeq=76 后仅新增 77/78 行；secret 无明文 |
| 复制摘要 | CLI/Swift 同组 golden 文本完全一致；按钮截图完整；实际点击粘贴与轻提示仍列人工项 |
| 发起方 | 通过：claude-code 启动、未命名 CLI agent=null、UI 停止 requestedBy.client=ui；截图与解码/文案测试覆盖 |
| 动态 | 通过：真实操作/配置/选项/任务取消/规则共 34 条；删除项目后无条目；secret 差异与截断另有回归 |
| 暂停 | 通过：UI 停止后 CLI 12、无新运行，override 可启动并标记；重启保留、释放后未命名 CLI 可启动；行内交互人工复核 |
| 锁定 | 通过：四种 CLI 动作均 12，UI 可停止/启动；排队 start 不被拒绝 stop 取消及竞态由真实 daemon 测试覆盖 |
| 强制停止规则 | 通过：默认 CLI 拒绝，UI 成功；allow/deny 两值回归通过 |
| 规则只能由界面修改 | 通过：CLI PUT 403 FORBIDDEN_CLIENT；配置不读写规则、删除服务清理均有回归 |
| 安装 | 本地包在无外部 Node、临时 HOME、仓库外中文空格目录完成注册/日志/启停/删除/daemon 关闭；干净 Mac 全流程和 Gatekeeper 仍需人工 |
| 资源 | 见下表；就绪后零额外端口读取由隔离注入计数证明，动态不可见零请求由真实场景计数验证；摘要仅请求时计算 |

真实联调脚本与记录在 .devpanel-dev/codex/v04/acceptance.mjs、acceptance.log、acceptance-result.json。恢复截图保留 unknown/日志缺口，不把它当作正常总览；README 使用不含个人路径的演示截图。

### 最终发布包

最终完整 App、ZIP 与 SHA 位于 .devpanel-dev/codex/v04/release/。App 内含官方 Node 24.21.0、本机架构 arm64 的原生界面/采样器、CLI、daemon、共享类型、生产依赖与第三方许可证。版本 0.4.0；App 常规文件合计 **138,384,558 bytes / 131.97 MiB**（不重复计软链接），ZIP **43,727,973 bytes / 41.70 MiB**。不发布、不签开发者证书、不公证、不安装用户稳定版。

最终 ZIP SHA-256：`5fe1c57a6da1a701535632df6465c4e14d7974cf65627bab59ca576f4223ca4e`。Node 独立运行时避免依赖本机 Homebrew Cellar/opt；只构建当前架构，Intel 需在对应机器另行构建和验收。

final-smoke.log 对应的仓库外副本使用 PATH=/usr/bin:/bin、临时 HOME/DEVPANEL_HOME，完成业务 stdout 脱敏、status、stop、remove、daemon stop。所有本轮记录身份的进程退出，remaining=[]；原始结果在 `/var/folders/8w/xyz6y3qd30n_8jfl2rjnsq6r0000gn/T/dp-pkg-goGsTK/result.json`。此验证覆盖运行时自包含，不等于干净 Mac 的完整桌面安装验收。

### 同条件资源复测

测法沿用 v0.3：同机/Node、release App、1180×760、空闲零项目，后台 active=false / hidden=false / onscreen=false；预热 10 秒，约 48 秒采样，三轮取中位数。CPU 为 proc_pid_rusage 累计 user+system 增量，100%=单核；RSS/footprint 为轮内中位数。每轮保存 PID+启动时间，10/30/55 点检查窗口状态，清理后再次核验。仅清空测试 bundle ID 的偏好；不动用户偏好。功能场景各一轮，动态两组窗口均在屏幕上、记录实际焦点，仅切换标签是否打开，不与后台空闲直接相减。

| 进程 | v0.3 CPU % | v0.4 CPU % | v0.3 RSS MiB | v0.4 RSS MiB | v0.3 footprint MiB | v0.4 footprint MiB |
| --- | --- | --- | --- | --- | --- | --- |
| 界面 | 1.150 | 0.101 | 97.75 | 92.30 | 28.17 | 28.20 |
| daemon | 0.193 | 0.109 | 65.77 | 52.48 | 38.08 | 38.71 |
| sampler | 0.003 | 0.003 | 0.88 | 0.88 | 1.20 | 1.20 |

| 轮次 | 秒数 | 界面 CPU % / RSS / footprint MiB | daemon CPU % / RSS / footprint MiB | sampler CPU % / RSS / footprint MiB |
| --- | --- | --- | --- | --- |
| 1 | 47.44 | 0.207 / 92.30 / 30.44 | 0.109 / 52.48 / 38.79 | 0.002 / 0.88 / 1.19 |
| 2 | 47.39 | 0.101 / 97.08 / 28.20 | 0.088 / 60.01 / 38.71 | 0.003 / 0.88 / 1.20 |
| 3 | 47.67 | 0.047 / 88.30 / 28.09 | 0.129 / 50.45 / 38.43 | 0.003 / 0.88 / 1.20 |

界面 footprint +0.03 MiB、daemon +0.63 MiB，未见明显空闲内存回退。CPU 数字较低，但当前用显式 orderOut 固定后台不可见状态，历史脚本仅记录同一组 CGWindow 字段，未记录 NSWindow.isVisible；不能据此归因于功能优化或声称严格复现历史所有窗口内部状态，也不代表长时间泄漏检查。正常 scene 的状态、尺寸和预热/采样方式一致。

| 场景 | 秒数 | 界面 CPU % / RSS / footprint MiB | daemon CPU % / RSS / footprint MiB | sampler CPU % / RSS / footprint MiB |
| --- | --- | --- | --- | --- |
| 等待就绪，后台 offscreen | 47.53 | 0.229 / 107.91 / 32.51 | 0.813 / 75.52 / 43.16 | 0.413 / 1.97 / 1.30 |
| 已就绪，后台 offscreen | 47.52 | 0.154 / 102.44 / 30.86 | 0.824 / 77.54 / 43.24 | 0.478 / 2.03 / 1.31 |
| 动态标签未打开，窗口 onscreen | 47.29 | 0.655 / 107.89 / 31.31 | 0.427 / 78.19 / 41.49 | 0.019 / 1.89 / 1.27 |
| 动态标签打开，窗口 onscreen | 47.37 | 0.671 / 110.58 / 33.99 | 0.347 / 68.06 / 41.04 | 0.006 / 1.09 / 1.25 |

等待组 LISTEN 总计数 20→116，已就绪组 6→30（包含正常 stats 读取，不是额外就绪读取）；离开 waiting 后零额外读取由 ready.test.ts 的注入计数测试隔离证明。动态未打开时 page=0→0，打开时 3→12；每 5 秒发 project.upsert，无活动条目轮询。摘要没有后台调度器，32 MiB 耗时见前文。

功能测量采用快照驱动，内容 1180×732、含标题栏外框 1180×760；原始记录保留其额外 500×500 不可见辅助窗口，主窗口按宽度 ≥900 筛选，未把首次 1180×788 的预检混入结果。动态预检曾被系统切回非前台，正式测量记录而不强求持续焦点，避免抢占用户桌面：未打开组第 10/30 点 active=true、55 点 false；打开组第 10 点 true、30/55 点 false。因此动态 CPU 差值不作为纯标签成本，零请求结论不依赖焦点。计数仪器每 500ms 落盘也有固定开销，不能把快照与正常空闲 scene 的差值当作纯功能开销。

脚本 idle-bench.py / scenario-bench.py、各轮 idle-*.json、idle-summary.json、scenario-summary.json 均留在 v04 忽略目录；测量期间没有并行构建或测试，正式七轮的进程全部按身份核验退出。

### 截图索引与界面决定

相对本文的本地证据目录：`../.devpanel-dev/codex/v04/`（被 Git 忽略）。以下均由 --snapshot 生成并实际查看；引导只展示，没有写入用户命令目录。

| 文件 | 内容 |
| --- | --- |
| [overview-dark.png](../.devpanel-dev/codex/v04/overview-dark.png) / [overview-light.png](../.devpanel-dev/codex/v04/overview-light.png) | 真实 Spring/Vite 已就绪、超时仍运行、发起方与复制摘要 |
| [recovery-dark.png](../.devpanel-dev/codex/v04/recovery-dark.png) / [recovery-light.png](../.devpanel-dev/codex/v04/recovery-light.png) | daemon 恢复后已就绪保留、进程/采集未知提示 |
| [activity-dark.png](../.devpanel-dev/codex/v04/activity-dark.png) | 项目动态、配置差异展开、日志导航、暂停/锁定 |
| [policy-dark.png](../.devpanel-dev/codex/v04/policy-dark.png) | 项目独立 AI 权限 sheet，强停默认关闭 |
| [ready-editor-light.png](../.devpanel-dev/codex/v04/ready-editor-light.png) | 服务卡片就绪条件与等待上限，保存不重启说明 |
| [installation-dark.png](../.devpanel-dev/codex/v04/installation-dark.png) / [installation-light.png](../.devpanel-dev/codex/v04/installation-light.png) | 首次引导、路径展示、登录默认关闭 |
| [readme-demo.png](../.devpanel-dev/codex/v04/readme-demo.png) | 无个人绝对路径的公开演示图，复制到 docs/images/devpanel-v04.png |

原生实现开始和最终检查时 ui-design-v4.md 均不存在；按产品 §2.5/3.4/4.4/5.6/7 和 v2/v3 视觉实现。自行选择的布局仅为 AI 权限独立 sheet、每服务卡片就绪分区、现有工具栏增加复制摘要。紧凑服务列可能截断来源/长错误文案，检查器提供完整信息；没有重排既有页面。

### 人工清单、提案与限制

- 实际点击复制摘要并粘贴、折叠后的搜索/选区复制；动态滚动分页、展开、过期运行导航；暂停悬停/允许按钮、右键锁定、权限 sheet 保存与取消；编辑就绪条件后下次启动生效。
- 系统通知授权、后台就绪超时通知、AI/CLI 操作不通知、点击通知导航；首次关闭/重开、登录项的桌面交互。
- 干净 Mac 无 Node/源码：下载/校验、Gatekeeper 放行、CLI 安装/覆盖确认/目标变化、目录 PATH、登录启动、移动 App 后重新安装、卸载。旧用户数据副本的人工迁移未执行。
- 待决三提案在 contract/CHANGES.md：ready.port 禁止 secret 引用（PARAM_INVALID）；inline 写回 JSON number；错误级别只认大写独立 ERROR/FATAL/SEVERE。均按任务说明先实现，未修改冻结契约。
- 公开名称、LICENSE、标签 v0.4.0 与发布由用户决定，本轮未添加许可证、打标签或推送。用户决定升级时，先停止受管服务并备份，按 release-v0.4.md 切换 App/CLI/登录项；旧稳定目录可保留回滚，不能同时对同一数据运行两版 daemon。
- 等待恢复 unknown、非持续健康检查、无 HTTP/依赖编排/自动重启/AI诊断等范围限制继续有效。

### 进程审计

本阶段真实联调、发布 smoke 和每轮资源脚本都保存本次身份并在结束核验退出；七轮资源测量共 21 个身份均无残留，复核见 final-process-audit.json；没有向用户 daemon 或稳定版发信号。全量测试本身的 cleanup 均通过。

更早监督线夹具 **PID 80657，PPID 1，2026-10-22 09:37:09** 仍存活，命令为监督工作树的 service.mjs silent。扫描已有 state/日志未找到启动时保存的身份记录，按任务硬规则没有发信号，因此**不能宣称全局零孤儿进程**。证据 supervision-evidence/stage2/legacy-fixture-80657.txt；需用户核对后明确授权或自行清理。此限制与本阶段已记录身份的清理结果分开报告，不以删除工作树掩盖进程问题。

## review 修复记录（2026-10-22）

### 第 1 组：契约落地与行为缺陷

提交：本节所在的 `fix(v0.4): apply accepted contract decisions and behavior fixes`（后续记录补充提交号）。完成修复提示第 1–7 项：shutdown 采用内部绕过规则的停止路径，保留请求方动态及已有暂停/锁定；mock 同步实际停止模拟服务。普通 logs 恢复 v0.3 服务、运行、tail、follow、JSON 的全部组合，digest/after-seq 仍互斥选择服务或运行。Python Traceback 包含异常末行且以该行去重，预算的最后错误按 lastOccurrenceSeq 选择；CLI/Swift 标题范围取实际扫描范围，共享 after-seq/truncated golden。就绪徽标只读 currentRun，历史运行继续保留就绪用时。project rules 补充接入就绪条件、start/restart --wait-ready、digest/after-seq 与退出码 11/12，和仓库 skill 一致。

接受并生效的五条提案均按用户交付修复提示的授权移入 CHANGES.md 已生效（用户确认 2026-10-22）；api.md §2/13/14/16 与 shutdown 类型注释同步，不改类型。没有其他契约扩展。

验证：先复现 Python 错误块 3≠2、最后错误选择 firstSeq=3≠2 两个失败，再修复为通过。全量 typecheck 2.194 秒；JS 227 项（daemon 103、CLI 22、mock 50、Web 52）103.575 秒；Swift build 7.629 秒、302 项/49 suites 的 test 命令 6.910 秒（用例 1.248 秒）；零编译 warning。证据 `.devpanel-dev/codex/v04/review/g1-*`。为安全运行全量测试，第二组的身份持续记录和有界等待先在工作区就位，独立提交在下一组；最终审计本轮 96 个夹具身份，0 残留。首次全量运行发现 runner 自测未适配新增包装器，已保留原 timeout/force-exit 标志并让自测实际覆盖包装器，复测通过。

### 第 2 组：测试与进程安全

第一组提交号：`d0b0d18`。本组提交为本节所在 `fix(v0.4): audit fixture processes and decouple mock behavior`。完成第 8–11 项：activity/policy/ready 持续保留身份，Manager 更换、删除历史均不丢失清理记录，t.after 负责兜底；所有新增长等待有截止，CLI 子进程等待加上限。digest/CLI 新用例不启动业务进程；mock 只用虚拟运行并停止定时器。daemon 测试包装器保留 timeout/force-exit 标志，以测试专用 preload 在进程存活时写身份台账，整套结束检查全部身份，泄漏时安全清理并判失败；CLI 的 runner 回归覆盖该包装器。

mock 的 ready.ts 独立实现配置校验、日志文字和虚拟端口就绪；摘要路由只返回 golden 固定样例，不再引用 daemon 源码。7 组共享 JSON/text golden（其中 6 组附生成输入）覆盖无错误、omitted、afterSeq、truncated、Python 异常末行、repeat 和原 repeated；daemon 校验生成内容，CLI 与 Swift 读取同批样例比对文本。

release smoke 在收集输出及写 result.json 之前检查敏感值，分别捕获每个清理失败，仍执行 daemon stop 和身份/命令指纹审计；必要兜底仅对保存且重新核验的身份发信号，发现泄漏仍判失败。新增清理步骤连续抛错、敏感输出拒绝的回归。

全量：typecheck 4.025 秒；JS 237 项（daemon 104 / CLI 28 / mock 53 / Web 52）144.646 秒；Swift build 5.328 秒；Swift 302 项/49 suites，test 命令 4.426 秒（用例 1.241 秒），零编译 warning。95 个夹具身份全部退出；ps 复核 service.mjs 无残留。证据 `.devpanel-dev/codex/v04/review/g2-*`。

本地产包 48.164 秒，隔离 smoke 8.284 秒；result 位于 `/var/folders/8w/xyz6y3qd30n_8jfl2rjnsq6r0000gn/T/dp-pkg-KoWxXH/result.json`。ZIP SHA-256 `1aca6644ddb37d3c04c7739d9ec499531200ed04759e9e76aaeb6e64d1085bbc` 为第二组检查点，最后一组后重新打包。

### 第 3 组：范围与配置冲突一致性

第二组提交号：`72b8664`。本组为本节所在 `fix(v0.4): align CLI scope and redact path-based config conflicts`。完成第 12–15 项：删除 CLI activity --before，HTTP before 分页保留；删除 Swift RunProcessInfo.startedBy，身份注释恢复紧邻 startedAt；保留 daemon 按路径逐条的 CONFIG_CONFLICT.diff，新增项目/服务/快捷操作环境变量与 secret 选项的双侧脱敏回归。mock 改为同一按路径语义，修复旧 masked 比较漏掉敏感值变更的冲突。原生错误解码读取整个数组，编辑器逐条显示路径；新增多路径与 secret 标记解码/展示测试。仓库 skill onboarding 第 5 步按 diff 通知用户，没有依赖单条整体格式；无需改写。CLI 安装器两个链接按产品已更新的范围保留。

全量：typecheck 2.313 秒；JS 239 项（daemon 105 / CLI 28 / mock 54 / Web 52）107.601 秒；Swift build 2.206 秒；Swift 303 项/50 suites，test 命令 4.362 秒，零编译 warning；夹具身份审计无残留。首次全量时主机负载令单次 CLI 冷启动超过新增测试的 5 秒上限，保留有界等待并调为 15 秒，重跑通过。证据 `.devpanel-dev/codex/v04/review/g3-*`。

### 第 4 组：代码质量与最终验收

第三组提交号：`0ca865c`。本组为本节所在 `refactor(v0.4): simplify actor flow and open contract enums`。完成第 16–20 项：mock 动态采用虚拟叶子差异和内存分页，规则用独立内存 Map、最小状态变更模拟，不复刻 daemon 持久化/恢复实现。daemon 配置比较与差异共用 comparable() 对选项响应元数据的处理，避免旧 diff 按键全局跳过同名 env 的错误；新增回归。manager 的等待默认值共用 readyTimeoutMs，params 两处就绪端口引用共用 helper。

server/manager/mock 的配置、操作、任务与选项入口只传 Actor，source/client 在需要处从 actor.client 推导，调用与测试同步，避免两份来源分叉。Swift ReadyCheckKind、ReadyState、Evidence.kind、LogDigestBlockKind 和 ActivityKind 改为现有 OpenEnum 模式，未知值可解码与往返，编辑草稿仍用 UI 字符串。mock 请求头显式 validateAgentHeader()，删除 void actor。只对 v0.4 新增 TS 文件统一双引号与正常空格，既有文件仅改本次接口调用和新增代码。

进程审计补充：cleanup helper 将独立夹具身份也汇入台账；新增故意泄漏测试，确认整个 daemon runner 会判失败、安全清理并复核，而非仅验证无泄漏的正常路径。原 runner 的 200ms 超时仍保留；主机高负载下外层进程启动保护上限调为 20 秒（故意泄漏验收 30 秒），不取消任何超时保护。

最终全量：typecheck 1.659 秒；JS **241 项**（daemon 106 / CLI 29 / mock 54 / Web 52）105.607 秒；Swift build 2.273 秒；Swift **304 项/50 suites**，test 命令 2.578 秒（用例 1.185 秒）；零编译 warning。最终台账 **103 个身份，0 残留**，另以 ps 只读复核没有任何 test/fixtures/service.mjs。证据 `.devpanel-dev/codex/v04/review/g4-*`。

最终发布包重建 45.759 秒，含中文/空格路径、最小 PATH、隔离 HOME/DEVPANEL_HOME 的 smoke 11.054 秒通过；result 位于 `/var/folders/8w/xyz6y3qd30n_8jfl2rjnsq6r0000gn/T/dp-pkg-kM5UXy/result.json`，本轮 daemon、采样器、服务身份全部消失，输出无敏感值。产物 `.devpanel-dev/codex/v04/release/DevPanel-0.4.0.zip`，SHA-256 **e7e10addabaf6933a9ea312aa88abd9f4565a018d2f0ed132be1da39f15d7851**。只在本地打包与 ad-hoc 签名，不发布、不推送、不签开发者证书或公证。

### 未完成、限制及人工项

- 四组代码修复全部完成。清理旧分支时严格运行 `git branch -d codex/v04-ai codex/v04-supervision`，Git 返回两者 not fully merged（旧工作树提交以重新提交方式进入 main，不是祖先关系）。按提示禁止 -D，保留两个分支，未改写历史或制造合并来绕过检查；这是本轮唯一未完成的清理项。
- readiness 保留每运行的 live tracking，并注明序列化仅供诊断，不用于续接旧管道；daemon 重启后的 waiting 仍为 unknown。没有实现旧管道续接。
- ERROR/FATAL/SEVERE 仍只认大写独立标题；npm ERR! 与 tsc error TS… 的识别留作后续候选，本轮不扩大契约。
- 人工验证：界面“停止所有服务并退出管理服务”后重开确认暂停/锁定保持；已停止服务不显示“已就绪”、运行记录仍显示历史用时；Python 日志折叠与复制摘要粘贴（特别是截断/增量）交互。此前通知授权、干净 Mac 安装/Gatekeeper/CLI 安装覆盖及迁移清单仍需用户验证。
- 用户原有 docs/product-design-v0.4.md 修改、未跟踪 prompts/codex-v0.4-fix.md 保留，不纳入修复提交。五条提案已全部确认生效，无新增待决提案。未碰用户稳定版 App/CLI/真实数据及 daemon。

## 用户追加：Git 改动列表可读性（2026-10-22）

用户要求参照 IDEA，清楚区分新增、修改、删除，并提供模块或目录分组。此处按本次追加授权改进原生展示，不扩展冻结接口。

- 文件名、状态图标与中文标签共同表达改动类型：修改蓝、新增/复制绿、删除红、重命名/类型变化紫、未跟踪琥珀、冲突红（图标与文字独立区分）。颜色依改动类型决定，与是否已暂存分开；同一文件两侧的状态独立展示。
- 保留已暂存、未暂存、未跟踪、冲突四组，新增“平铺 / 目录树 / 目录分组”和状态筛选。目录树默认展开，顶层目录保留，单子目录链紧凑显示为 src/main/java，可折叠；目录分组严格按路径首段，例如 backend/frontend，根目录文件单列。没有扫描磁盘或推断业务模块。
- 重命名显示原路径，行数增删分别用绿/红显示；保留差异窗口、暂存、提交和储藏行为。Shift 范围选择改为使用当前可见顺序；折叠或筛选后清理不可见选择，避免快捷键操作隐藏项。筛选期间组操作明确标为“暂存筛选项 / 取消暂存筛选项”。布局和筛选保存在本次应用会话中。
- 将文件浏览器提取为 GitChangesView，纯路径布局与两侧状态映射位于 DevPanelKit/State/GitFileList.swift；没有改写冻结的共享类型与 api.md。

验证：隔离 DEVPANEL_HOME 下 Swift 构建通过（3.72 秒），全量 **310 项 / 51 suites** 通过（用例 1.202 秒），无编译 warning/error。新增 6 项覆盖两侧不同状态、目录折叠与计数、紧凑路径、顶层分组、按显示顺序 Shift 选择及 5,000 文件不丢失；git diff --check 通过。没有修改 TypeScript，未重跑 JS 测试。

渲染使用隔离 mock（127.0.0.1 随机端口）与显式合成 GitStatus，不访问或操作用户的仓库。使用现有 --snapshot 渲染器，增加只读 --git-layout / --git-filter / --git-status-fixture 参数。已检查浅色、深色、窄窗口、平铺与删除筛选，无重叠或标签截断；目录树经初次截图检查后压缩连续空目录链。证据目录为 `.devpanel-dev/git-browser/`：tree-light.png、tree-dark.png、directories-narrow.png、flat-light.png、deleted-filter.png，日志 swift-all.log，各图同名 .log，夹具 status.json，复现脚本 render.py。mock 按本轮记录的 pid + 启动时间核验后正常退出，已复核进程消失及发现文件删除。

限制：真正的业务模块、自定义路径分组、多仓库与多个 Maven 工程仍需后续显式配置设计；AI 登记目录的方向已记录在 contract/CHANGES.md 待决提案，尚未变更契约或落地实现。本次不升级 /Applications/DevPanel.app、不替换稳定版 CLI/daemon、不读写真实数据、不产出新的发布压缩包。

### 2026-10-22 v0.4.1：显式仓库 / Maven 工程与本地升级准备

- 用户要求由 AI 重新核对现有项目配置，先打最新版 tag 并安装本地。按该授权落地 v1.4-A（契约 §17）：`repositories` / `mavenProjects` 明确登记相对目录，旧配置兼容，无自动发现；未知 / 歧义 ID 拒绝回退，真实路径限制在项目内。
- daemon / CLI / mock / Swift 类型同步。全部 Git 路由按 `repositoryId`，Maven 模型与运行按 `mavenProjectId`，CLI 增加 `--maven-project`。Maven 在所选工程根解析模型、找 wrapper、执行并保存目标 ID / cwd；仍限制同项目一个运行。注册 / 校验 / 更新均不执行项目命令。
- 原生面板提供仓库 / 工程切换、名称路径与编辑入口；Git / Maven 页始终可见。编辑器保留并编辑目标数组；Git 缓存、选择、消息、差异窗口和确认按仓库隔离；Maven 模型、模块 / Profiles / 参数与日志历史按工程隔离。Git 文件状态色和三种目录布局沿用前节实现。
- 配置 skill 同步说明 AI 根据实际文件登记目标，补齐已有配置时只改目标数组，保留命令、敏感值与用户选项，不执行构建或服务。
- 验证：`pnpm typecheck` 通过；全量 `pnpm test` daemon 109、CLI 29、mock 55 全通过，daemon fixture 审计 106 个身份全部退出；Swift 313 测试 / 52 suites 通过，无编译警告。新增回归验证 sibling 仓库同名文件写入隔离、错误 selector、路径 / 符号链接逃逸、嵌套工程 wrapper / cwd、CLI / 历史 ID 与配置往返。
- 多目标原生截图在 `.devpanel-dev/local-upgrade/targets-git-{light,dark}.png`、`targets-maven.png`，已人工查看。快照只用隔离 mock，结束后按 pid + 启动时间核验退出。
- 本地 release 使用独立 Node 24.21.0，版本 0.4.1，输出 `.devpanel-dev/local-upgrade/release-verified/`。ZIP SHA-256 为 `c382a9bc471d9e776fd09d15cac3578fd3616cc2322d821ace5b3283791a9692`。未推送、未创建 GitHub Release。
- 真实配置只读盘点：demo-workspace 三仓库 / 两 Maven 根（聚合工程 聚合与 Worker 工程）；demo-api 与 demo-services 各根仓库 / backend Maven；demo-web front 根仓库 / 无 Maven。排除 `.local` 历史副本与 POM 聚合子模块，不拆项目。
- 安装前发现 demo-services 三服务仍运行。现有 daemon 的 shutdown API 要求停止全部服务，外部退出后无法接续旧 stdout 管道、服务将标 unknown；因此不能承诺无中断升级。安装与配置变更在包验证通过后按明确的运行服务处理方案执行，并单独记录结果。

- 真实目标只读预检全部通过：demo-api 1 模块、demo-workspace 聚合工程 10 模块 / Worker 1 模块、demo-services 1 模块；无 POM 解析错误，均按现有有效 PATH 找到 mvn。没有执行 Maven。配置补丁已在忽略目录私有保存，未修改真实配置。

### 2026-10-22 v0.4.1 本地安装与真实配置完成

- 用户明确同意短暂重启 demo-services 三服务，升级后恢复；其余项目不启动。本地版本 tag `v0.4.1` 指向 `d2f62bf`，未推送。
- 正常退出旧界面，调用旧 daemon 的 shutdown（stopServices=true）优雅停止三个服务；返回 succeeded，旧服务 PID 均退出。daemon 正常退出后才复制数据。
- 完整备份：`~/.local/share/devpanel/backups/before-upgrade-<timestamp>/`，包含旧 App、数据、旧配置 skill。备份目录 0700，数据及敏感文件维持私有权限。
- 安装已验证的独立运行时 App 至 `/Applications/DevPanel.app`，daemon 与 App 均确认 0.4.1。原有 `~/.local/bin/devpanel` / `devpaneld` 链接仍指向 App 内嵌入口。同步 `~/.agents/skills/devpanel`，保留 `~/.codex/skills/devpanel` 的现有软链接。
- 四项目按最新 revision 整体更新，仅追加 repositories / mavenProjects：demo-workspace 6→7（3 仓库 / 2 Maven），demo-api 2→3（1 / 1），demo-services 6→7（1 / 1），demo-web 2→3（1 / 0）。逐字段比较确认所有原服务、快捷操作、选项与敏感值未变，托管规则及暂停状态未变。demo-api 既有隧道命令 WARN_SHELL_COMPOUND 保留，未修改其原命令。
- 在真实 daemon 逐一只读验证 6 个仓库、4 个 Maven 工程：Git root 与登记目录一致；Maven 10 / 1 / 1 / 1 模块、无解析错误。未执行 Git 写操作或 Maven 构建。
- 仅恢复 demo-services 的 agent-runtime / backend / frontend 三服务，启动操作 succeeded。原配置未登记就绪条件，因此额外验证：Agent `/health/live` 与 `/health/ready` 200，后端 `/actuator/health` 200 且 UP，前端 `/` 200；日志也确认 Uvicorn startup complete 与 Next Ready。其他项目维持原停止 / 失败 / idle 状态。
- 历史共 28 条；三次恢复启动按原有每服务留存策略淘汰 3 条最旧 demo-services 运行，全部原始历史及日志可从升级前完整备份恢复。其他项目历史未变。
- 原生界面实查通过：demo-workspace Git 显示 Java 后端仓库选择器、路径与目录树；Maven 显示 聚合工程 聚合工程选择器、Profiles 和模块树。当前已打开 demo-workspace Maven 面板，Git 页在旁边。
- 验收证据（忽略目录）：`.devpanel-dev/local-upgrade/config-migration.json`、`live-targets.json`、`installed-audit.json`、`projects-after-install.json`。未将真实配置、敏感数据或备份纳入 Git。


### 2026-10-23 工程工具归属与日志可读性反馈

- 用户指出项目级 Git / Maven 入口难以理解，并明确“日志缩短”指时间、线程、包名等前缀。按本轮授权调整原生交互；不扩展 Git / Maven 操作范围，不改接口契约、真实项目配置或稳定版安装。
- 工具入口移至服务行与服务检查器。按 `cwd` 和已登记目标路径的最长祖先关系确定仓库 / Maven 工程，使用完整目录边界并规范化 `.` / `..`，不按名称或列表顺序猜目标。服务页只显示目标名称与路径；切换工程同步更新 Git scope、Maven selector 与任务日志。菜单快捷键也遵循当前服务。
- 项目详情默认进入快捷操作或动态；已关联服务的工具不再重复显示项目标签，未关联工程以及显式空配置保留项目页入口，防止工具失联。旧的根目录 Maven 兼容根服务或直接 java / mvn / mvnw 服务。旧配置的实际目录精度仍受现有登记内容限制，本轮不自动扫描或修改用户配置。
- `LogPresentation` 保守识别 Spring Boot 与两类常见 Logback / Log4j 格式：精简为“时间 级别 类名 : 正文”，默认开启，可关闭或悬停查看原文。时间保留毫秒；未知格式与系统行原样显示。INFO 绿色、WARN / WARNING 琥珀色、ERROR / FATAL / SEVERE 红色，DEBUG / TRACE 次级文字色。颜色独立于 stdout / stderr，正文 ANSI 样式仍保留。
- 原始日志缓存不变，显示投影重新映射 ANSI 与 UTF-16 位置。搜索使用原文，匹配行恢复完整前缀；整行 / 全量复制包含原始前缀，中文 / emoji 局部选择保持正确。堆栈折叠规则不变。
- 验证：Swift 320 测试 / 54 suites 通过；`pnpm typecheck`、`pnpm test` 通过（daemon 109、CLI 29、mock 55、Web 52，共 245）。debug build、release bundle 均成功，编译日志无 warning / error；`git diff --check` 通过。回归覆盖目录边界、最深工程、前后端切换、Maven 任务日志归属、级别误识别、ANSI、Unicode、空正文与原文复制。
- 使用独立 mock 与虚构项目生成原生截图，目录 `.devpanel-dev/codex/v04/readability/`：`logs-dark.png` / `logs-light.png`（六行日志示例与精简前缀）、`frontend-git.png`（前端仓库）、`backend-maven.png`（Java 构建）、`logs-search.png`（隐藏线程名搜索与自动还原）、`logs-original.png`（关闭精简）。已检查深浅色与工具归属；三种日志模式的 `--verify-folding` 均输出 `raw-copy true`、`search-visible true`。
- 本地开发包：`.devpanel-dev/codex/v04/readability/build/DevPanel.app`，仅 ad-hoc 签名；未安装、未推送、未创建标签或 Release。没有运行 Maven、启动真实服务或访问真实数据目录。隔离 mock 按记录的 PID 与启动时间核验后关闭。
- 未自动验证的交互：用户真实日志中的非标准自定义布局、真实系统菜单焦点与手动鼠标操作；未知日志格式不做猜测或截断。已有未跟踪文件 `prompts/codex-v0.4-fix.md` 保持不变。

### 2026-10-25 GitHub 开源前整理

- 用户要求先整理仓库，随后明确选择 MIT。新增根目录 `LICENSE`（2026 Hugo）、贡献与安全报告指南、第三方声明、文档导航、Issue / PR 模板和只读权限的 macOS CI；没有创建远程仓库、推送、标签或 GitHub Release。
- README 补充功能入口、独立 demo、准确的隔离构建步骤与 MIT 声明；原生 README 修正旧版本及“不能独立分发”的过时说明。文档和历史任务中的个人绝对路径改为示例路径，旧安装记录中的项目名与备份时间示例化；不修改冻结契约。现有未提交 Swift 实现与测试逐文件核对，内容保持原样。
- `.gitignore` 补充环境文件、密钥和日志，保留脱敏 `.env.example`。整理前检查 423 个已跟踪文件与本地全部 refs 的 1,147 个文本 blob，整理后检查 440 个当前文件，常见密钥格式均无命中。旧录制样本、路径格式化注释与用例中的个人用户名改为 demo，相关 Swift 320 项与 Web 52 项重跑通过。发现旧提交作者使用工作邮箱，早期历史含本机路径及安装记录；当前文件脱敏不清除历史，公开策略记录在 `docs/open-source.md`。
- 新增 `examples/demo/`，实测临时数据目录下的注册、启动、日志就绪、HTTP 响应、摘要、动态、停止、移除和 daemon 退出；发现文件已清除。发布脚本随 App 携带 MIT 与第三方声明，smoke 检查两份文件；@nodable/entities 3.1.0 的 npm 包缺失完整许可文本，已从发布 gitHead 对应的上游 LICENSE 补入第三方声明；ZIP / SHA-256 文件名增加 macOS / 架构，避免附件同名。
- 检查中发现 Git 超时测试的临时可执行脚本启动握手不稳定：直接 / pnpm 的单跑及全量表现不同，仅改 CommonJS 的对照未解决，因此撤回。最终将夹具放入显式 `.mjs`，由 shell exec 当前 Node，并将身份握手的准备等待限定为 8 秒；产品的 10 秒超时及父子进程、身份、退出断言不变。初轮采样器的两个时序失败在独立重跑及最终全量中均通过，无采样器实现变更。全部临时诊断脚本已清除。
- 最终 `pnpm typecheck`、`pnpm test`、`pnpm build` 通过；TypeScript / Web 245 项（109 / 29 / 55 / 52）全通过，daemon fixture 106 个身份无残留；Swift 320 项 / 54 suites 全通过。新增文档入口链接、YAML、脚本语法与 `git diff --check` 通过。
- 本地 `VERSION=0.4.2-dev` 完整 arm64 包、签名核验及无外部 Node smoke 通过，MIT 和第三方声明逐字节核对一致。产物 `.devpanel-dev/open-source/release/DevPanel-0.4.2-dev-macos-arm64.zip`，SHA-256 `7946948b93edad0af43da196f3861adfcab45c0843a1b141bc75edf97eb312ae`。它是预览包，不是版本升级或正式发行。
- 首次公开另备无 Git 历史的源码快照 `.devpanel-dev/open-source/DevPanel-source-preview.zip`，排除 `.git`、node_modules、构建物与运行数据；原本地仓库历史保留。实际 GitHub CI、Intel 包与干净 Mac 的安装 / 登录启动 / 通知交互仍需在对应环境验证。本轮未操作真实数据、稳定版 App / CLI 或日常 daemon。

### 2026-10-25 首次 GitHub 开源推送

- 维护者在整理后明确要求配置公开 GitHub 仓库并推送当前代码。GitHub connector 与浏览器均确认账号 `CnHugo76`，创建公开仓库 `CnHugo76/DevPanel`，MIT 与文档沿用本轮整理结果。
- 当前 440 个源码文件与整理时审阅的源码快照一致。旧历史和当前源码在本地备份分支完整保留；本地 `main` 从全新根提交开始，采用 GitHub noreply 邮箱，不上传旧历史、标签、忽略目录或运行数据。配置 `origin` / `origin/main`，首次只推送 `main:main`；没有创建 GitHub Release 或升级已安装组件。
- 这次提交前只更新公开状态记录；代码验证沿用本节前的 TypeScript / Web 245 项、Swift 320 项、构建与发布包 smoke 结果。首次 GitHub CI 的实际结果以远程 Actions 为准。

### 2026-10-25 中英文仓库介绍

- 按维护者要求补齐双语介绍：`README.md` 默认英文，`README.zh-CN.md` 保留完整简体中文，两者顶部互相切换；文档导航列出两个入口。
- 两份说明覆盖同一组功能、安装与 CLI 引导、Agent 接入、源码构建、数据与升级、卸载、限制和 MIT 许可。英文页明确详细开发文档 / demo / skill 仍主要使用中文，两份说明均注明原生界面尚未完成多语言支持。
- GitHub About 简介同步使用简体中文与英文。此轮只修改介绍与文档，检查本地链接、两份说明的命令 / 代码块一致性及 `git diff --check`，不重复运行产品测试。
