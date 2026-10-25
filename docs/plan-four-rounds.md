# 四轮优化执行与验收

2026-10-25，用户确认按产品评估中的四轮顺序完成优化。该授权覆盖下述新功能方向；共享契约仍遵循 AGENTS.md 的提案确认流程。实现与证据汇总同时链接到 plan-v0.4.md。全部运行使用临时 DEVPANEL_HOME；只产出本地包，不替换日常 App/CLI/daemon、不推送、不创建公开发行。

| 轮次 | 范围 | 验收出口 | 状态 |
| --- | --- | --- | --- |
| 1 安装与接入 | 可重复进入的接入帮助、PATH/CLI 自查、随包独立示例、双语快速开始、产物来源清单与隔离安装 smoke | 无外部 Node/源码能运行示例；新旧 CLI 覆盖、移动 App 和卸载场景有可复验结果 | 本机验收完成；目标机器交互另列 |
| 2 状态与排查 | 问题优先状态、就绪证据/下一步、运行与下次参数差异、复制排查信息、保留日志全文检索、管理中断说明 | 失败能定位证据；秘密值不出现在复制/检索；长输出/切换运行不串数据 | 本机验收完成 |
| 3 配置复用 | 可分享配置、导出/导入预览、本机输入、显式仓库文件同步规则、示例与指引 | 跨目录复用；秘密与机器路径不导出；保存/导入不启动；revision 和用户值保护 | 本机验收完成 |
| 4 AI 并行使用 | 可选工作标识、动态筛选、实例分组与明确归属 | 两任务/两目录并行时来源、日志、端口配置、接管规则互不混淆 | 本机验收完成 |

## 范围与取舍

- 继续使用原生 Theme、现有总览/检查器/sheet，保持键盘和可访问标签；不重做导航。
- 不扩 Git/Maven 操作范围，不做 HTTP 探测、自动重启、远程/容器、内置聊天或 MCP。
- 第四轮选择轻量实例分组，不做审批流程或自动 worktree 生命周期管理。
- 仓库配置采用显式预览/导入；本机配置为当前有效值，不做双向自动同步。
- daemon 管道无缝恢复需要另行设计，本轮完善可解释状态与可操作的处理流程，不承诺重连旧 stdout。
- 干净 Mac 的 Gatekeeper、登录会话与真实通知交互以及 Intel 发行验收，需要对应环境；本机隔离验证单独记录，不能替代。

## 契约

用户在本轮对话明确同意 [v1.5-A/B/C](../contract/CHANGES.md)，共享语义与类型已同步。

## 验证记录

每轮记录具体命令、结果、已知限制与截图；提交前完成仓库要求的 TypeScript/Swift 门槛。最终重建完整包，核验来源、版本、许可证、校验值及无外部 Node 的隔离 smoke。用户日常环境不参与开发验收。

### 第一轮

- 原生：可重复打开的接入指引，CLI 链接只读检查，正确引用的 PATH/Agent 指令，随包 skill 与快速开始入口。源码模式使用隔离目录，不建议无 --bin-dir 的 setup:cli。Swift 325 项/55 suites 通过，无编译 warning/error；深浅色与最小窗口截图通过。
- 发布：随包携带 demo、双语快速开始和 skill，源码提交/dirty/文件指纹与 ZIP SHA-256 写入清单；构建期间源码变化会拒绝出包。
- TypeScript typecheck 通过；全量测试 246 项（daemon 109、CLI 30、mock 55、Web 52）通过。独立安装 smoke 发现 demo 入口的 /var 与 /private 符号链接差异；修正后 demo 两项回归通过，增加的新用例将在最终全量统计。
- `0.4.2-round1` arm64 完整包在仓库外中文空格目录、无外部 Node、临时 HOME/DEVPANEL_HOME 下，通过临时 CLI 链接运行。带 secret 的业务日志验证、随包 demo 注册/就绪/摘要/动态/停止/移除、daemon 退出与进程身份审计通过，remaining=[]。最后只删除本轮创建的链接。
- 证据：`.devpanel-dev/four-rounds-round1-{tests,release,smoke}.log`；截图 `.devpanel-dev/four-rounds/onboarding-bundled.png`。包位于 `.devpanel-dev/four-rounds/round1-release/`，SHA-256 为 `c7502761886de8d49678e27c28d6a9fcb5f25a0e6dc4cdc05afc4dee5f06355a`。这是中间预览，最终包另行生成。
- 未执行目标 Mac 的 Gatekeeper 放行、真实登录/通知交互及 Intel 打包；没有升级用户安装，也没有公开发布。

### 第二轮

- 保留日志搜索覆盖 daemon、CLI、独立 mock 和原生界面。普通文本/ANSI/中文、一万行旧日志命中、固定 through 分页、截断、非法查询、secret 不恢复均通过。
- 原生问题状态区分进程存在与就绪；实际运行/下次配置对照固定所选 run，环境只展示已知 keys；排障复制限制 48 KiB，支持摘要/首个错误上下文。迟到响应、运行切换、空分页和失败重试有回归。
- TypeScript typecheck 通过；全量测试 253 项（daemon 112、CLI 34，包含提前完成的 3 项配置复用纯函数验证、mock 55、Web 52）通过。fixture 审计 105 个身份、0 残留。
- Swift build 无 warning/error；334 tests / 57 suites 通过。根 Agent 已查看深色就绪超时、浅色历史运行对照、900×560 搜索截图，无控件裁切。
- 证据：`.devpanel-dev/four-rounds-round2-{typecheck,search-tests,integration,tests}.log`；`/tmp/devpanel-r2-{state-dark,command-light,search-dark,search-light-small}.png`。

### 第三轮

- CLI 导出/导入及本机输入已实现；JSON Pointer 限定在已知标量位置，拒绝原型属性、重复和结构目标，读取分别限制 1 MiB / 64 KiB。
- 纯函数 3 项、真实 HTTP/CLI 集成通过：不覆盖已有导出、秘密/路径不输出、默认预览不写入、不产生运行、显式应用、不同 root 独立、revision 冲突不重试、用户值继续保留。
- 原生 349 tests / 59 suites、build、diff --check 通过；补齐取消后的迟到保存回包、FIFO/NUL/空路径/文件大小、秘密缺失、revision 冲突、不覆盖输出。CLI→Swift 的类型化秘密/路径/instance，以及 Swift→CLI 导出均通过互通验证。
- 隔离 mock 的原生导入实际保留用户端口 8081，服务保持 idle/currentRun=null；根 Agent 查看深色导出、900×560 浅色预览、保存成功提示截图通过。截图在 `.devpanel-dev/four-rounds/import-{preview,saved}.png`。
- 证据：`.devpanel-dev/four-rounds-round3-integration.log`、`four-rounds-portable-final-integration.log`、`four-rounds/interop/`；加入 portable demo 和双语分享说明。本机绝对路径 enum choices 会拒绝导出并提示改 string 参数，避免留下旧路径或静默改枚举语义。

### 第四轮

- Actor 工作 ID/URI 编码名称、CLI 参数优先级、动态先筛选后 limit、ProjectConfig/ProjectView 实例显示信息已接入；UI 请求忽略工作头，工作上下文在持久化前严格遮盖已知 secret。
- 真实双目录并行验证通过：不同 run/log，暂停一个不会影响另一个，快捷操作启动和取消分别保留工作 ID，工作动态筛选正确；磁盘 Actor 未泄露短/长 secret。此次 fixture 审计 3 个身份、0 残留。
- 原生工作来源覆盖动态、操作和运行；手动工作筛选可以查找不在当前分页中的工作，切换项目/条件会清空旧分页并拒绝迟到响应。实例分组/名称可编辑，总览和检查器同时展示根目录、项目 ID，并支持 `group:` / `instance:` 搜索。
- 实际编辑一个实例名称后仅该项目 revision 从 2 变为 3；另一实例仍为 2，两个 run ID、根目录、工作 ID 均未变化，也没有重启。深浅色及 900×560 截图复核通过，窄列完整显示主状态，运行记录徽标与就绪状态颜色一致。
- Swift 最终 361 tests / 61 suites 通过，build 无 warning/error。隔离 mock 按记录的 PID 与启动时间全部停止，0 残留。
- 证据：`.devpanel-dev/four-rounds-round4-{typecheck,integration,activity-tests}.log`；`.devpanel-dev/four-rounds/native-final/` 保存最终原生测试日志、截图、实例保存和清理记录。

### 整合检查

- 当前 TypeScript 全量 259 项通过（daemon 115、CLI 35、mock 57、Web 52），fixture 审计 109 个身份、0 残留；随后可分享格式边界调整的纯函数与真实 CLI 集成再次通过，非空实例名称与 200 个 Unicode 标量的检索边界回归通过。根 typecheck、build、diff --check 均通过。
- 检索样本：180,000 行、32,462,704 字节；无命中扫描 9.24 ms/响应 113 bytes，50 处命中 5.40 ms/响应 41,973 bytes。仅为本机一次已构造缓冲区测量，不包含采集耗时，不是所有分布的性能上限。证据 `four-rounds/search-benchmark.json`。
- 最终本地预览包路径为 `.devpanel-dev/four-rounds/release/DevPanel-0.4.2-preview-macos-arm64.zip`。打包时冻结源码；来源提交、dirty 状态、逐文件指纹、ZIP SHA-256 和实际 smoke 结果汇总到 `.devpanel-dev/four-rounds/final-acceptance.json`，以该生成记录为最终发行验收依据。
- 完整 smoke 覆盖仓库外中文空格目录、临时 HOME/data、无外部 Node、CLI 链接、日志脱敏/全文检索、随包示例就绪、配置导出/预览/显式导入、实例独立且保持 idle、中文工作名称与动态筛选，以及服务/daemon 退出后的进程身份审计。Gatekeeper、真实登录/通知交互及 Intel 架构仍需目标机器验收。

### 本地安装升级（用户另行授权）

- 2026-10-25，用户在四轮验收后明确要求创建 tag 并升级本地安装，使用 `v0.4.2-preview`。先提交源码，再从 tag 对应的干净工作区重建；带来源提交的包位于 `.devpanel-dev/four-rounds/tagged-release/`，不推送远端。
- 安装前检查发现 daemon 的版本仍写死为 `0.4.1`，已改为读取所属包的版本；完整包 smoke 同时核对 daemon 响应及发现文件版本与发布清单一致。
- 升级先备份旧 App 和停止后的数据，保留 CLI 的长期 App 路径，只恢复升级前仍在运行的服务。机器本地的备份位置、安装版本与服务恢复结果写入 `.devpanel-dev/four-rounds/local-upgrade-result.json`，不把用户数据纳入仓库。
