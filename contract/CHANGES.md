# 契约变更记录

规则见 `AGENTS.md` 的“契约变更”一节。最新的写在最上面。

## 待决提案

暂无。

## 已推迟

### [推迟] Git 提交钩子的实时输出 — 提出方：backend — 2026-10-21
- 动机：ui-design-v3 §5.3 要求钩子输出实时显示，但 §12 仅在提交 HTTP 完成后返回 output / details.output，没有提交运行 ID 或流式端点。
- 具体差异：若需要实时输出，建议后续定义提交操作 ID、只读输出流及终态查询；本版不自行扩展冻结契约。
- 对另一方影响：原生提交状态需订阅新操作流，mock 也需模拟输出事件。
- 确认前实现：提交期间显示进行中，结束后显示完整受限输出和钩子失败横幅；已有服务和任务日志不受影响。
- 状态：用户确认推迟（2026-10-21）；本版提交结束后显示钩子输出，ui-design-v3 §5.3 同步。

## 已生效

### [已生效] v1.4-A AI 显式登记项目下的 Git 仓库与 Maven 工程 — 提出方：backend — 2026-10-22
- 动机：一个 DevPanel 项目可以是多个服务的集合，其根目录下可能有前后端两个独立 Git 仓库，Maven 聚合根也可能位于子目录。现有 §12 把仓库固定为项目 root 所在工作树，§11.3 把 Maven 固定为 root/pom.xml，不能表达这种布局。用户选择由配置项目的 AI 明确登记目录，程序不递归猜测项目结构。
- 用户已确定的方向：AI 负责识别并填写配置；程序只按登记的目标展示、校验和操作。允许一个 DevPanel 项目挂多个仓库、多个 Maven 工程；人仍可在编辑项目时修改。不要求拆分项目、移动目录或重建已有服务。用户随后直接要求完成新版、打 tag、安装并配置项目；本次实现采用以下字段与接口。
- 建议的配置差异（类型与语义见 api.md §17）：
  ```ts
  // ProjectConfig 新增可选字段；数组顺序即显示顺序。
  repositories?: { id: string; name: string; path: string }[];
  mavenProjects?: {
    id: string;
    name: string;
    path: string;
    executable?: 'auto' | 'wrapper' | 'mvn';
  }[];
  ```
  - path 为相对项目 root 的目录，可用 `.`；不支持选项占位符。规范化真实路径后须在项目 root 内，拒绝越界及符号链接逃逸；同类目标 id 唯一、真实目录去重。
  - Git path 指向明确的工作树根目录（支持普通仓库与 worktree），不从公共父目录搜索子仓库。Maven path 指向含 pom.xml 的工程根；其 modules 仍按 POM 声明静态解析，不再发现额外工程。
  - AI 在初次登记或补充已有配置时填写上述数组；人可编辑。注册、更新与校验不执行构建、服务或 Git 写命令，也不因配置保存就运行目标。
  - 未提供新字段的旧配置保留原有根目录行为；显式空数组表示未登记目标，不自动发现。旧 `maven.executable` 仅用于旧根目录目标；显式 mavenProjects 各自使用 executable。
- 接口与语义差异：
  - Git 的 status、diff、stage、unstage、commit、stashes、stash、stash/apply 全部需要能指定 repositoryId；Maven 模型、运行请求、历史与 CLI 需要能指定 mavenProjectId。目标只能来自已保存配置，运行接口不接受任意目录。
  - 显式列表有一个目标时可省略选择；有多个目标时省略须返回明确错误，不能静默选第一个。旧配置继续使用旧根目录目标；未知 id 必须报错，不能回退。
  - 项目视图需提供目标列表及各 Maven 目标的 currentRun / lastRun；Maven 运行记录、快捷操作中保存的 Maven 请求需记录目标 id，运行详情快照保存实际 cwd，旧记录仍可读取。
  - Maven moduleId、pomPath、`-pl`、wrapper 解析与执行 cwd 改为相对所选 Maven 工程根；项目 env 继续沿用。首轮建议保留同一 DevPanel 项目最多一个 Maven 运行的现有并发限制，不顺带扩展任务调度。
  - Git 文件路径、HEAD 校验、暂存、提交、储藏全部限定在所选仓库；保留写操作仅界面可发起的约束，不做跨仓库批量提交。
- 界面影响：Git 页选择仓库，Maven 页选择工程；显示目标名称与路径。缓存、文件选择、diff 窗口、提交信息与刷新状态按项目 + 目标隔离，防止切换后串仓库操作。显式空列表显示“尚未登记 Git 仓库 / Maven 工程”并提供编辑入口，不能只隐藏面板让人无法判断原因。
- 另一方影响：设计方需确认配置字段、目标选择方式、空状态与旧配置兼容策略；随后同步 api.md、TypeScript / Swift 类型、daemon、CLI、mock、原生编辑器和 skills/devpanel 的 onboarding / 更新指引。
- 验收例子：`cosmetic/` 本身无 .git 或 pom.xml，登记 `cosmetic-java-server/` 与 `cosmetic-vue/` 两个仓库，登记 `cosmetic-java-server/jeecg-boot/` 为 Maven 工程；同一项目中分别查看两仓库，只操作选中仓库，Maven 在登记的工程根执行。保存配置不启动服务或构建；原有服务、选项与运行历史保留。
- 兼容限制：保留旧配置行为，不自动发现目标；同项目最多一个 Maven 运行。业务模块自定义映射不在本次范围，先支持按实际目录分组。
- 状态：用户于 2026-10-22 直接要求实现、打本地 tag、安装新版并补齐已有项目配置；按该授权生效，同步实现、mock、原生编辑器与配置 skill。



### [已生效] v1.3-D 关闭管理服务不经过托管规则 — 提出方：frontend（设计）— 2026-10-22
- 动机：v0.4 review 发现，`POST /daemon/shutdown`（`stopServices: true`）停止服务时按请求方走托管规则。后果有两个：
  - 界面“停止所有服务并退出管理服务”会让所有服务进入暂停，下次启动后 AI 无法启动任何服务；
  - 有锁定服务时，CLI 的 `daemon stop --stop-services` 会在停掉其他服务和任务之后失败。

  关闭管理服务不是“针对某个服务的停止”，§16 的本意不覆盖它。
- 变更：在 api.md §2 的 shutdown 行与 §16 写明以下三点。
  - shutdown 发起的停止**不经过托管规则**：不产生暂停，不受锁定或 `agentForceStop` 拒绝；
  - 已有的暂停与锁定保持不变；
  - 动态照常记录这次停止的 `operation` 条目，发起方为请求方。
- 影响：
  - daemon 与 mock 的 shutdown 路径绕过规则；
  - 新增测试：界面 shutdown 后没有暂停；锁定服务存在时 CLI shutdown 成功。
- 状态：用户确认（2026-10-22）。

### [已生效] v1.3-B Python Traceback 合为一个错误块 — 提出方：frontend（设计）— 2026-10-22
- 动机：按现行 §14，Python Traceback 的标题都是 `Traceback (most recent call last):`，签名完全相同，所以不同的 Traceback 会被去重成一块。真正的异常行（如 `ValueError: …`）又因不是堆栈行，被切成另一个错误块。
- 变更：§14 错误块规则补充两点。
  - 以 `Traceback (most recent call last):` 开头的块，在其堆栈行之后，把紧接着的第一条非缩进行（异常行）并入本块，块到此结束；
  - 该块的签名改用这条异常行（同样把连续数字替换为 `#`）；没有异常行时仍用标题行。
- 影响：daemon 摘要、CLI / Swift 文本格式不变；golden 样例增加 Python 用例；原生日志折叠按同一规则。
- 状态：用户确认（2026-10-22）。

### [已生效] v1.3-A 就绪端口禁止引用敏感选项 — 提出方：backend — 2026-10-22
- 动机：端口是对外展示的证据与监听元数据，不能用它隐式暴露敏感数字值。
- 变更：建议 `ready.check.port` 引用 `secret` 选项时按 PARAM_INVALID 拒绝；阶段4依任务说明先这样实现。
- 影响：daemon、mock 与表单校验同步，类型无需变化。
- 状态：用户确认（2026-10-22）。

### [已生效] v1.3-A 删除选项写回就绪端口的类型 — 提出方：backend — 2026-10-22
- 动机：整值占位符删除后不能写回数字字符串，否则不满足就绪端口契约。
- 变更：`inline=true` 删除被 `ready.check.port` 引用的 number 选项时，将当前值写为 JSON number；阶段4依任务说明先这样实现。
- 影响：daemon、mock 与原生删除预览保持数值端口，类型无需变化。
- 状态：用户确认（2026-10-22）。

### [已生效] v1.3-B 日志级别标题区分大小写 — 提出方：backend — 2026-10-22
- 动机：§14(a) 未明确大小写，普通文字中的 error 不应触发错误块。
- 变更：建议仅匹配独立的大写单词 ERROR / FATAL / SEVERE；本阶段按任务说明先采用此解释。
- 影响：CLI、原生与 mock 共用此语义；类型与路由不变。
- 状态：用户确认（2026-10-22）。

### [已生效] v1.3-A 就绪条件与 `--wait-ready` — 提出方：frontend（设计）— 2026-10-21
- 动机：产品 v0.4 §2。`running` 只表示进程还在；agent 现在靠 `logs --tail` 自行寻找就绪行，结果不确定且费 token。需要由 AI 登记、由 daemon 判断的就绪信号，以及一条命令拿到“是否就绪 + 出错摘要”的 CLI。
- 变更：
  ```ts
  export type ReadyCheck =
    | { kind: 'log'; contains: string[] }          // 1–5 项，每项 1–200 字符；区分大小写；去掉 ANSI 后对每行做子串匹配；不支持正则
    | { kind: 'port'; port?: number | string };    // 缺省 = 任意 TCP LISTEN；number 1–65535；string 只能是 "${key}"，引用 number 类型选项
  export interface ReadyConfig {
    check: ReadyCheck;
    timeoutSec?: number;                           // 默认 120，1–900
  }
  // ServiceConfig 新增：
  ready?: ReadyConfig;

  export type ReadyState =
    | 'not-configured'      // 本次运行启动时服务没有就绪条件
    | 'waiting'
    | 'ready'
    | 'timed-out'           // 超过 timeoutSec；只做标记，不停止进程
    | 'ended-before-ready'  // 运行在就绪前结束（含 spawn 失败、启动观察期退出）
    | 'unknown';            // daemon 重启后无法续接判断
  export interface ReadyInfo {
    state: ReadyState;
    at: Timestamp | null;                          // 进入 ready / timed-out 的时刻
    afterMs: number | null;                        // ready 时相对 startedAt 的毫秒数
    evidence: null
      | { kind: 'log'; seq: number }               // 匹配行的 seq
      | { kind: 'port'; port: number; address: string };
  }
  // RunSummary 新增（服务运行；任务运行不涉及）：
  ready: ReadyInfo;                                // 旧记录读出为 { state: 'not-configured', at: null, afterMs: null, evidence: null }

  // ParamReference.where 新增 'ready'（开放枚举；serviceId 为引用它的服务）

  // CLI --wait-ready 的输出（--json 时 stdout 始终为此对象，无论成功失败；退出码见下）
  export interface CliStartReport {
    operation: Operation;
    services: {
      serviceId: ServiceId;
      runId: RunId | null;
      outcome: TargetOutcome;
      ready: ReadyInfo | null;                     // 没有运行时为 null
      listening: ListeningPort[] | null;           // 报告生成时的真实端口
      digest: LogDigest | null;                    // 仅 ended-before-ready / timed-out / failed 时提供（依赖 v1.3-B；B 未接受时改为 tail: LogLine[]，最多 50 行）
    }[];
  }
  ```
  | 方法 | 路径 | 请求 | 响应 |
  | --- | --- | --- | --- |
  | GET | `/runs/:runId/ready/wait` | `?timeoutMs=`（≤ 60000） | `RunSummary`；`ready.state` 离开 `waiting` 或长轮询到期即返回。任务运行 → 400 `BAD_REQUEST`（`details.reason = "task-run"`） |
  - 语义：
    - 运行启动时快照就绪条件（端口占位符按当时选项值替换），每次运行独立判断。
    - 日志条件从 seq 1 开始，扫描 `out` / `err`（不含 `sys`）。端口条件在等待期间至少每秒读取一次该运行已核验进程的监听套接字（复用 §5 的采集方式），就绪或结束后停止额外读取。
    - `ready` / `timed-out` / `ended-before-ready` 为终态，不再检查。超时不发信号、不改变服务状态。
    - 就绪状态变化触发 `project.upsert`（`currentRun.ready`），不新增事件类型。
    - daemon 重启：仍为 `waiting` 的运行，如果能按 §8 恢复且日志能续接，就从已处理的 seq 之后继续判断，等待上限仍从 `startedAt` 起算；否则为 `unknown`。
    - `configChangedSinceStart` 不比较 `ready`。
    - 校验：`contains` 为空或越界、`port` 不合法、`timeoutSec` 越界、`"${key}"` 指向不存在或非 number 的选项 → `CONFIG_INVALID`（`PARAM_UNKNOWN` / `PARAM_INVALID` 沿用）。注册 / 校验不执行任何命令。
  - CLI：
    ```bash
    devpanel start|restart <project-id> [--service <id>]... --wait-ready [--ready-timeout <sec>] [--json]
    ```
    - 先按现有规则等操作结束，再对 outcome 为 `started` / `already-running` 的目标调用 `ready/wait`，直到离开 `waiting`。
    - `--ready-timeout` 只限制 CLI 的等待，不改变 daemon 的判断；CLI 等待到期时退出码 8。
    - 退出码优先级：操作本身非 0（1 / 5 / 6 / 7 / 9 / 12）照旧；否则有 `ended-before-ready` → 1，有 `timed-out` → 11，其余 → 0。`not-configured` 视为 0，并在 stderr 提示。
    - 非 `--json` 时输出可读的报告。
  - §9 退出码表补充：**10** 任务运行超时（v1.2-C 已使用，api.md 表中漏列，本提案顺带补上）；**11** 就绪超时（`--wait-ready`）。
- 影响：
  - 后端：配置校验、就绪判断（日志匹配、等待期端口读取）、运行记录持久化、重启续接、`ready/wait` 路由、CLI `--wait-ready` 与报告。
  - 原生程序：就绪标记、编辑 sheet 的就绪分区、运行记录就绪用时、超时通知。
  - mock：服务按脚本输出就绪行与端口。
  - skill：用 `--wait-ready` 取代手动找就绪行；接入时登记就绪条件。
- 状态：已接受并生效（用户确认，2026-10-21），已写入 `api.md` §§2、§3、§4.3、§9、§13 与 `packages/contract`。类型说明：响应中新增的字段在 `index.ts` 里标为可选，只为兼容旧 daemon、并让尚未实现的 daemon / mock 继续通过 typecheck；api.md 规定 v1.3 daemon 必须返回这些字段。

### [已生效] v1.3-B 日志摘要与增量读取 — 提出方：frontend（设计）— 2026-10-21
- 动机：产品 v0.4 §3。agent 读日志只能整段拉取；需要按字节预算、确定性的错误块 / 堆栈折叠 / 重复合并摘要，以及按行号增量读取。界面“复制摘要”使用同一结果。
- 变更：
  ```ts
  export interface DigestLine {
    seq: number;
    stream: LogStream;
    text: string;                                  // 去掉 ANSI；单行超过 1 KiB 截断并以 "…" 结尾
    repeat?: number;                               // 与本行完全相同的连续行数（含本行），≥ 2 时出现
    folded?: { lines: number; lastSeq: number };   // 本行之后被折叠的堆栈行
  }
  export interface LogDigestBlock {
    kind: 'error' | 'tail';
    firstSeq: number;
    lastSeq: number;
    occurrences: number;                           // error：同签名错误块出现次数（≥ 1）；tail：1
    lastOccurrenceSeq: number;                     // error：最后一次出现的标题行 seq
    lines: DigestLine[];
  }
  export interface LogDigest {
    runId: RunId;
    afterSeq: number | null;                       // 请求的起点
    lastSeq: number | null;                        // 摘要覆盖到的最新行
    scannedLines: number;
    errorBlocks: number;                           // 去重后的错误块总数
    blocks: LogDigestBlock[];                      // 错误块按首次出现时间排列，tail 在最后
    omitted: { errorBlocks: number; bytes: number };
    truncated: boolean;                            // 起点之前或范围内有内容已被日志上限丢弃
    runEnded: boolean;
  }
  ```
  | 方法 | 路径 | 请求 | 响应 |
  | --- | --- | --- | --- |
  | GET | `/runs/:runId/digest` | `?afterSeq=&maxBytes=`（默认 8192，1024–65536）`&tail=`（默认 20，0–200） | `LogDigest`；服务与任务运行通用 |
  - 语义（确定性规则，原生程序的折叠规则保持一致）：
    - **错误标题行**：去掉 ANSI 后满足任一条件。
      - (a) 含独立单词 `ERROR` / `FATAL` / `SEVERE`；
      - (b) 行首（允许前导空白）匹配 `^[A-Za-z_$][\w$.]*(Exception|Error)(: |$)`；
      - (c) 以 `Traceback (most recent call last):` 或 `panic:` 开头。

      只因 `stream = err` 不算。
    - **错误块** = 标题行 + 紧随其后的堆栈行。堆栈行是：`^\s+at `、`^\s*(Caused by|Suppressed): `、`^\s+\.\.\. \d+ (more|common frames omitted)`、`^\s+File "`，以及 Python Traceback 内缩进的代码行。遇到第一条非堆栈行，错误块结束。
    - **折叠**：保留标题、前 5 个 `at` 帧、每个 `Caused by` / `Suppressed` 行及其后 2 帧，其余用 `folded` 表示。
    - **签名去重**：标题行文字中的连续数字替换为 `#` 后作为签名；同签名的错误块只保留第一次，`occurrences` 与 `lastOccurrenceSeq` 记录次数和最后一次。
    - **预算**：按序列化后的 `blocks` 字节计。依次放入：第一个错误块、最后一个错误块、tail，然后按时间补其余错误块；放不下的计入 `omitted`。单个块超出剩余预算时截取其前部，并在 `omitted.bytes` 计入。
    - 只读、按请求计算，不缓存、不常驻分析；不调用模型，不给出原因解释。
  - CLI（新增参数，原有行为不变）：
    ```bash
    devpanel logs <project-id> (--service <id> | --run <run-id>) --digest [--after-seq <n>] [--max-bytes <n>] [--json]
    devpanel logs <project-id> (--service <id> | --run <run-id>) --after-seq <n> [--tail <n>]   # 对应 GET …/logs?after=n
    ```
    非 `--json` 的文本格式由 api.md 定义，原生程序“复制摘要”使用同一格式。格式示例：标题 `[run r_… · 行 1–3204 · 2 个错误块，省略 0]`，每块以 `── ERROR ×50（最后 3101 行）──` 开头，折叠处为 `    … 省略 37 行堆栈`。
- 影响：
  - 后端：摘要计算、路由、CLI 参数与文本格式。
  - 原生程序：日志工具栏“复制摘要”，堆栈折叠规则与契约对齐。
  - mock：摘要路由（可用固定样例）。
  - skill：读日志优先 `--digest`，修改后用 `--after-seq`。
- 状态：已接受并生效（用户确认，2026-10-21），已写入 `api.md` §§2、§9、§14 与 `packages/contract`。类型说明：响应中新增的字段在 `index.ts` 里标为可选，只为兼容旧 daemon、并让尚未实现的 daemon / mock 继续通过 typecheck；api.md 规定 v1.3 daemon 必须返回这些字段。

### [已生效] v1.3-C 操作来源（agent 名称）与项目动态 — 提出方：frontend（设计）— 2026-10-21
- 动机：产品 v0.4 §4。现有 `Operation.source` 只区分 ui / cli，运行记录和停止原因没有记录发起方。agent 无法判断 `lastRun.exit.reason = 'user-stop'` 是否由自己发起（skill 现有规则依赖这一判断）；面板也看不出服务是谁启动的、配置是谁改的。
- 变更：
  ```ts
  /** 可选请求头；仅 cli 请求有意义，ui 请求带此头时忽略。自报名称，不是认证。 */
  export const AGENT_HEADER = 'X-DevPanel-Agent' as const;  // 值匹配 /^[a-z0-9][a-z0-9._-]{0,31}$/，否则 400 BAD_REQUEST
  export interface Actor {
    client: ClientKind | 'daemon';
    agent: string | null;                          // 来自 AGENT_HEADER；client ≠ 'cli' 时恒为 null
  }
  // Operation 新增：actor: Actor                       （source 保留，恒等于 actor.client）
  // RunSummary 新增：startedBy: Actor | null           （旧记录 null）
  // TaskRunSummary 新增：startedBy: Actor | null       （source 保留）
  // ExitInfo 新增：requestedBy: Actor | null
  //   reason 为 user-stop / force-stop / start-cancelled 时是发起停止（或取消）的一方；
  //   任务运行被取消时是取消方；timeout / self-exit / spawn-failed / daemon-lost 时为 null

  export type ActivityDetail =
    | { kind: 'operation'; operationId: OperationId; action: ActionKind; serviceIds: ServiceId[]; state: OperationState;
        results: { serviceId: ServiceId; outcome: TargetOutcome; runId: RunId | null; errorCode: ErrorCode | null }[];
        overrideHold?: boolean }                     // v1.3-D
    | { kind: 'config'; change: 'register' | 'update' | 'param'; fromRevision: number; toRevision: number;
        changes: ConfigDiffEntry[]; changesTruncated: boolean }   // 最多 100 条；敏感值一律为 { secret: true }
    | { kind: 'task-run'; runId: RunId; taskKind: TaskRunKind; label: string; state: TaskRunState }
    | { kind: 'policy'; serviceId: ServiceId | null; change: 'hold' | 'release' | 'lock' | 'unlock' | 'settings' };  // v1.3-D
  export interface ActivityEntry {
    id: string;                                    // "a_" + ULID
    projectId: ProjectId;
    at: Timestamp;
    actor: Actor;
    detail: ActivityDetail;
  }
  export interface ActivityPage { entries: ActivityEntry[]; hasMore: boolean }
  // Limits 新增：activityKeptPerProject（默认 500）
  ```
  | 方法 | 路径 | 请求 | 响应 |
  | --- | --- | --- | --- |
  | GET | `/projects/:id/activity` | `?before=<activityId>&limit=`（默认 50，≤ 200） | `ActivityPage`，新 → 旧 |
  - 语义：
    - 写入时机：operation 结束时写入一条（终态）；配置注册 / 更新 / 选项路由保存成功时写入一条（幂等注册 `created:false` 不写）；任务运行结束时写入一条（取消方见该运行的 `exit.requestedBy`）。
    - 超出 `activityKeptPerProject` 时删最旧的条目；删除项目时一并删除。
    - 不新增事件类型：客户端在动态可见时，收到 `operation` / `project.upsert` 后重新读取。
    - 选项 `setBy` 语义不变（ui → user，cli → agent），agent 名称只在动态中体现。
  - CLI：
    - 全局参数 `--agent <name>`，环境变量 `DEVPANEL_AGENT`（参数优先）；有值时所有请求附带 `X-DevPanel-Agent`；不合法 → 退出码 2。CLI 不推断名称。
    - `devpanel activity <project-id> [--limit <n>] [--json]`
    - `devpanel project rules` 输出中加入设置 `DEVPANEL_AGENT` 的说明。
- 影响：
  - 后端：头部校验、各记录增加发起方、动态存储与保留、路由、CLI 参数与命令。
  - 原生程序：服务行 / 检查器的发起方说明、项目检查器“动态”标签（含配置差异展开）。
  - mock：动态样例与各字段。
  - skill：说明 `DEVPANEL_AGENT`；判断“用户主动停止”改为看 `exit.requestedBy.client === 'ui'`。
- 状态：已接受并生效（用户确认，2026-10-21），已写入 `api.md` §§1.1、§2、§9、§15 与 `packages/contract`。类型说明：响应中新增的字段在 `index.ts` 里标为可选，只为兼容旧 daemon、并让尚未实现的 daemon / mock 继续通过 typecheck；api.md 规定 v1.3 daemon 必须返回这些字段。

### [已生效] v1.3-D 托管规则：停止后暂停、锁定、AI 强制停止 — 提出方：frontend（设计）— 2026-10-21
- 动机：产品 v0.4 §5。“用户停止后不要自行重启”“强制停止由用户决定”目前只写在 skill 里；需要由 daemon 执行、只能由界面修改的规则。依赖 v1.3-C（用 `Actor` 判断停止的发起方并记录越过）。
- 变更：
  ```ts
  export interface ProjectPolicy {
    holdAfterUserStop: boolean;                    // 默认 true
    agentForceStop: 'allow' | 'deny';              // 默认 'deny'（用户确认）
    lockedServices: ServiceId[];                   // 默认 []
  }
  export interface ServiceHold {
    since: Timestamp;
    operationId: OperationId;                      // 产生暂停的界面停止操作
  }
  // ProjectView 新增：policy: ProjectPolicy
  // ServiceView 新增：hold: ServiceHold | null; locked: boolean
  // ActionRequest 新增：overrideHold?: boolean      （仅 cli 请求有意义；ui 请求忽略）
  // ErrorCode 新增：'POLICY_DENIED'   details: { reason: 'hold' | 'locked' | 'force-stop'; serviceId: ServiceId }
  ```
  | 方法 | 路径 | 请求 | 响应 |
  | --- | --- | --- | --- |
  | GET | `/projects/:id/policy` | – | `ProjectPolicy` |
  | PUT | `/projects/:id/policy` | `ProjectPolicy` | `ProjectPolicy`；仅 `ui` 客户端，其他 → 403 `FORBIDDEN_CLIENT`；`lockedServices` 含不存在的服务 → 422 `CONFIG_INVALID` |
  | DELETE | `/projects/:id/services/:serviceId/hold` | – | 204；仅 `ui` 客户端 |
  - 语义：
    - 规则不属于 `ProjectConfig`：注册 / 更新 / 校验既不读取也不写入；新项目使用默认值。更新配置删除服务时，从 `lockedServices` 中一并移除。
    - **产生暂停**：`holdAfterUserStop = true` 时，`ui` 发起的 stop / force-stop（服务级或项目级）中 outcome 为 `stopped` / `stop-timeout` 的目标进入暂停。已在暂停中的保留原 `since`。
    - **解除暂停**：`ui` 发起的 start / restart 使该目标 outcome 为 `started` / `already-running`；`DELETE …/hold`；`cli` 带 `overrideHold: true` 的 start / restart 成功启动；`holdAfterUserStop` 被改为 false（清除该项目全部暂停）。暂停持久化，daemon 重启后保留。
    - **拒绝**：以下 `cli` 目标的 outcome 为 `failed`，`error.code = 'POLICY_DENIED'`，不创建运行、不发信号。
      - start / restart 命中暂停且未带 `overrideHold`；
      - 任何动作命中 `lockedServices`（`overrideHold` 对锁定无效）；
      - `agentForceStop = 'deny'` 时的 force-stop。
    - 被拒绝的 stop / force-stop 目标**不参与** §4.2 停止优先：不取消同一服务排队中或执行中的 start / restart。
    - `ui` 请求永远不受规则约束。
    - 规则变化、暂停产生与解除写入动态（`kind: 'policy'`）；带 `overrideHold` 的操作在其 operation 条目标记 `overrideHold: true`。规则与暂停的变化触发 `project.upsert`。
    - 范围：只约束服务的 start / stop / restart / force-stop；快捷操作、Maven、选项、配置路由不受影响。
    - 安全说明（写入 api.md）：客户端类型来自请求头，同一用户下的程序都能取得 socket 与 token；本机制防误操作，不是对抗恶意程序的安全边界。
  - CLI：
    - `start|restart` 新增 `--override-hold`。
    - 新增 `devpanel policy <project-id> [--json]`，只读；CLI 不提供修改规则的命令。
    - `status` 输出暂停 / 锁定。
    - 新增退出码 **12**：操作中失败的目标全部是 `POLICY_DENIED`（且没有其他失败原因）。混合结果沿用 6 / 1。
- 影响：
  - 后端：规则存储、暂停状态机、操作拒绝与停止优先例外、路由、CLI。
  - 原生程序：暂停 / 锁定标记与“允许 AI 启动”、右键锁定、项目设置“AI 权限”。
  - mock：规则与拒绝行为。
  - skill：处理退出码 12，只在用户本轮明确要求时使用 `--override-hold`，删去现在由 daemon 执行的文字规则。
- 状态：已接受并生效（用户确认，2026-10-21），已写入 `api.md` §§2、§4.2、§9、§16 与 `packages/contract`。类型说明：响应中新增的字段在 `index.ts` 里标为可选，只为兼容旧 daemon、并让尚未实现的 daemon / mock 继续通过 typecheck；api.md 规定 v1.3 daemon 必须返回这些字段。 用户确认：`agentForceStop` 默认 `'deny'`；允许 `--override-hold`。

### [已生效] 任务 lastRun 语义统一 — 提出方：backend — 2026-10-21
- 用户在 v0.3 review 中授权统一：ActionView.lastRun 与 maven.lastRun 均取最近一次已结束记录；currentRun 单独表示当前运行。
- api.md、index.ts 字段注释、daemon / mock / 原生客户端同步；不改变类型或路由。


### [已生效] 差异响应增加文件版本指纹 — 提出方：backend — 2026-10-21
- 动机：差异窗口获得焦点时比较 GitDiff，可识别已返回文本的变化；相同大小二进制或截断区外的变化无法可靠识别。
- 具体差异：建议 GitDiff 增加可比较的内容版本指纹（baseOid / newOid：Git blob oid，涵盖基准与新内容），客户端用于提示“文件已变化”。
- 对另一方影响：daemon / mock 返回指纹，原生窗口比较指纹后提示刷新；无需常驻文件监听。
- 确认前实现：仅比较现有响应内容，明确上述检测限制，不扩展冻结类型。
- 状态：用户确认并生效（2026-10-21），api.md / index.ts 与实现同步。

### [已生效] Maven goals 排除开关前缀 — 提出方：backend — 2026-10-21
- 动机：§11.3 的 goal 正则允许 `-o`、`--help` 等以 `-` 开头的字符串，Maven 会将其解释成开关，与“只接受结构化参数、不接受任意参数”的要求冲突。
- 具体差异：在现有正则之外明确 goals 每项不得以 `-` 开头；未知请求字段也拒绝。
- 对另一方影响：UI / mock / CLI 应显示 MAVEN_INVALID；正常阶段与插件目标不受影响。
- 确认前实现：为遵守结构化命令安全要求，拒绝上述输入，记录为现有正则允许范围的限制；未修改 api.md 或共享类型。
- 状态：用户确认并生效（2026-10-21），api.md / index.ts 与实现同步。

### [已生效] 任务日志流的结束载荷 — 提出方：backend — 2026-10-21
- 动机：§11 指定任务复用 `/runs/:runId/logs/stream`，但 `LogStreamEvent.end.run` 仍只有服务的 `RunSummary`。
- 具体差异：建议将类型扩大为 `RunSummary | TaskRunSummary`，并在 api.md §6.4 说明按运行种类返回；客户端以 runId 与 endedAt 关闭订阅。
- 对另一方影响：Swift 与 Web 日志流需兼容两种结束载荷；不影响日志 lines / gap / truncated。
- 确认前实现：保留现有 end 类型，任务采用底层服务运行投影（succeeded→exited、cancelled→stopped；serviceId 为 action:<id> 或 maven:），真实任务状态从 project.upsert 与 `/task-runs/:runId` 获取。
- 状态：用户确认并生效（2026-10-21），end.run 返回真实任务摘要。



### [已生效] v1.2-C Maven 视图与快捷操作（第 2 稿） — 提出方：frontend（设计）— 2026-10-21
- 动机：产品 v0.3 §2（第 2 稿）。用户要的是 IDEA 式 Maven 视图（模块、生命周期、Profiles、开关），AI 只定义快捷操作；两者都是“跑完即结束”的运行，托管方式与服务相同。第 1 稿的“任务”改名为“快捷操作”。
- 变更（全部为新增，不改变已有字段语义）：
  ```ts
  // ── 快捷操作（AI 定义） ──
  export type ActionId = string;          // 与 ServiceId 相同格式；项目内唯一（独立命名空间）
  export interface ActionConfig {
    id: ActionId;
    name: string;                         // 按钮文字，例如 "clean install -DskipTests"
    description?: string;
    cwd: string;
    command: string[];                    // 支持 ${key} 占位符，规则同 api.md §3.1
    env?: EnvMap;
    stopTimeoutSec?: number;              // 取消后等待，默认 10，1–300
    timeoutSec?: number;                  // 最长运行时间；缺省不限；1–86400
    confirmWhenServicesRunning?: boolean; // 仅提示客户端确认
  }
  // ProjectConfig 新增：
  actions?: ActionConfig[];
  maven?: { executable?: 'auto' | 'wrapper' | 'mvn' };   // auto（缺省）= 有 mvnw 用 mvnw，否则 PATH 中的 mvn

  // ── Maven 模型（daemon 静态解析 pom.xml，不运行 Maven、不联网、不读 ~/.m2） ──
  export const MAVEN_PHASES = ['clean', 'validate', 'compile', 'test', 'package', 'verify', 'install', 'site', 'deploy'] as const;
  export interface MavenModule {
    id: string;                           // 相对项目根的模块目录，根模块为 "."（同时用作 -pl 的值）
    pomPath: string;                      // 相对项目根
    parentId: string | null;              // 通过 <modules> 聚合它的模块
    groupId: string | null;               // 本 POM，或 <parent> 中的值
    artifactId: string;
    name: string | null;
    packaging: string;                    // 缺省 "jar"
    profiles: string[];                   // 本 POM 声明的 profile id
    parentOutside: boolean;               // <parent> 指向的 POM 不在项目内
    error: string | null;                 // 本 POM 解析失败的原因（此时其余字段尽量填）
  }
  export interface MavenModel {
    executable: 'wrapper' | 'mvn';        // 实际将使用的
    modules: MavenModule[];               // 根模块在前，按 <modules> 深度优先
    profiles: string[];                   // 全部模块 profile 去重
    scannedAt: Timestamp;
  }
  export interface MavenRunRequest {
    moduleId: string;                     // 必须是 MavenModel.modules 中的 id
    goals: string[];                      // 生命周期阶段或插件目标，按给定顺序传给 mvn
    profiles?: string[];                  // "id" 启用，"!id" 禁用
    skipTests?: boolean;                  // -DskipTests
    offline?: boolean;                    // -o
    alsoMake?: boolean;                   // -am（仅 moduleId 不是 "." 时有效）
  }

  // ── 运行（快捷操作与 Maven 共用；第 1 稿的 TaskRun 改为以下形态） ──
  export type TaskRunKind = 'action' | 'maven';
  export type TaskRunState = 'running' | 'cancelling' | 'succeeded' | 'failed' | 'cancelled' | 'timed-out' | 'unknown';
  // ExitReason 新增：'timeout'
  export interface TaskRunSummary {
    id: RunId;                            // 与服务运行共用 RunId 命名空间（日志路由通用）
    projectId: ProjectId;
    kind: TaskRunKind;
    actionId: ActionId | null;            // kind = action 时
    maven: MavenRunRequest | null;        // kind = maven 时
    label: string;                        // 显示用，例如 "clean install · backend"
    configRevision: number;
    source: ClientKind;
    startedAt: Timestamp; endedAt: Timestamp | null;
    pid: number | null;
    state: TaskRunState;
    exit: ExitInfo | null;
    cancelTimedOut: boolean;
  }
  export interface TaskRunDetail extends TaskRunSummary {
    command: string[];                    // 实际执行的 argv（secret 片段为 ••••）
    cwd: string; envKeys: string[];
    params: Record<string, ParamValue | { secret: true }>;
    log: LogInfo; processes: ProcessInfo[];
  }
  export interface ActionView {
    id: ActionId; name: string; description: string | null; confirmWhenServicesRunning: boolean;
    currentRun: TaskRunSummary | null; lastRun: TaskRunSummary | null;
  }
  // ProjectView 新增：
  actions: ActionView[];
  maven: null | { currentRun: TaskRunSummary | null; lastRun: TaskRunSummary | null };   // null = 项目根没有 pom.xml
  // ProjectStats 新增：tasks: Record<RunId, ServiceStats>（运行中的任务运行；total 一并计入，按身份去重）
  // Limits 新增：taskRunsKept（默认 5，快捷操作每个、Maven 每项目各自保留）、logBytesPerTaskRun（默认 16 MiB）
  // usedBy 中快捷操作的引用：serviceId 填 "action:<actionId>"
  // ErrorCode 新增：'ACTION_NOT_FOUND' | 'TASK_RUNNING' | 'MAVEN_UNAVAILABLE' | 'MAVEN_INVALID'
  ```
  | 方法 | 路径 | 请求 | 响应 |
  | --- | --- | --- | --- |
  | GET | `/projects/:id/maven` | `?reload=1` 可强制重新解析 | `MavenModel`；项目根无 `pom.xml` → 404 `MAVEN_UNAVAILABLE` |
  | POST | `/projects/:id/maven/runs` | `MavenRunRequest` | 202 `{ run }`；已有 Maven 运行 → 409 `TASK_RUNNING`（`details.runId`）；参数不合法 → 422 `MAVEN_INVALID` |
  | GET | `/projects/:id/maven/runs` | – | `TaskRunSummary[]`（新 → 旧） |
  | POST | `/projects/:id/actions/:actionId/runs` | – | 202 `{ created: true, run }`；已在运行 → 200 `{ created: false, run }` |
  | GET | `/projects/:id/actions/:actionId/runs` | – | `TaskRunSummary[]` |
  | POST | `/task-runs/:runId/cancel` | `{ force?: boolean }` | 202 `TaskRunSummary`；已结束 → 200 |
  | GET | `/task-runs/:runId` | – | `TaskRunDetail` |
  - Maven 命令构造（daemon 负责，客户端不传任意参数）：`<mvnw 或 mvn> [-pl <moduleId> [-am]] [-DskipTests] [-o] [-P<p1,p2>] <goals...>`，在项目根执行，环境为项目级 env。校验：`goals` 每项匹配 `^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+){0,3}(@[A-Za-z0-9_.-]+)?$`；`profiles` 每项匹配 `^!?[A-Za-z0-9_.-]+$`；`moduleId` 必须存在；否则 422 `MAVEN_INVALID`。找不到 `mvnw` / `mvn` → 422 `COMMAND_NOT_FOUND`。
  - pom 解析只读取 XML 结构（`<modules>`、坐标、`<packaging>`、`<profiles>`、`<parent>`），不展开属性占位符以外的继承；按各 `pom.xml` 修改时间缓存。
  - 运行语义：同一项目同一时刻最多一个 Maven 运行；同一快捷操作最多一个运行；不同快捷操作可并行；取消 / 强制取消 / 超时 / 日志 / 资源 / 进程核验 / daemon 重启核验与服务一致；不自动重跑；注册 / 更新 / 校验不执行任何快捷操作；删除运行中的快捷操作或项目 → 409 `TASK_RUNNING`。
  - 事件：通过 `project.upsert`（`ProjectView.actions`、`ProjectView.maven`）推送，不新增事件类型。
  - CLI：
    ```bash
    devpanel action list <project-id> [--json]
    devpanel action run <project-id> <action-id> [--no-wait] [--follow] [--timeout <sec>] [--json]
    devpanel maven modules <project-id> [--json]
    devpanel maven run <project-id> [--module <id>] [-P <p>]... [--skip-tests] [--offline] [--also-make] <goal>... [--no-wait] [--follow] [--json]
    devpanel task cancel <run-id> [--force] [--json]
    devpanel logs <project-id> --run <run-id> [--tail <n>] [--follow]
    ```
    运行类命令默认等到结束；退出码：0 成功，1 失败，9 已取消，10 超时，8 等待超时，其余沿用 §9。
- 影响：后端新增 pom 解析、Maven 运行、快捷操作、通用任务运行托管、CLI 与测试；原生程序新增 Maven 页、快捷操作行与页、编辑 sheet 的快捷操作分区；mock 同步（含一个多模块的假 Maven 项目）。
- 状态：已接受并生效（用户确认 plan-v0.3 第 2 稿的全部决定，2026-10-21），已写入 `api.md` §2、§9、§11、§12 与 `packages/contract`

### [已生效] v1.2-D Git 基础能力（第 2 稿：列表优先 + 差异窗口） — 提出方：frontend（设计）— 2026-10-21
- 动机：产品 v0.3 §3。查看改动、暂存、提交、储藏不必再打开 IDE。
- 变更（全部为新增）：
  ```ts
  export type GitChange = 'modified' | 'added' | 'deleted' | 'renamed' | 'copied' | 'typechange' | 'unmerged';
  export interface GitEntry {
    path: string;                         // 相对仓库根，'/' 分隔
    origPath: string | null;              // 重命名 / 复制的来源
    index: GitChange | null;              // 已暂存的变化
    worktree: GitChange | null;           // 未暂存的变化
    untracked: boolean;
    conflicted: boolean;
    sensitiveName: boolean;               // 文件名命中敏感模式（见下）
  }
  export interface GitStatus {
    repo: null | {                        // null = 项目根不在 Git 仓库中
      root: string;                       // 绝对路径
      branch: string | null;              // 分离 HEAD 时为 null
      headSha: string | null;             // 空仓库时为 null
      upstream: string | null;
      ahead: number; behind: number;      // 无上游时为 0
    };
    entries: GitEntry[];
    truncated: boolean;                   // 超过 5,000 条时截断
    checkedAt: Timestamp;
  }
  export interface GitDiffLine { kind: 'context' | 'add' | 'del' | 'meta'; text: string; oldNo: number | null; newNo: number | null }
  export interface GitDiff {
    path: string;
    staged: boolean;
    binary: boolean;
    oldSize: number | null; newSize: number | null;   // 字节；用于二进制文件提示
    truncated: boolean;                   // 超过 5,000 行或 2 MiB
    additions: number; deletions: number;
    hunks: { header: string; lines: GitDiffLine[] }[];
  }
  export interface GitStash { ref: string; message: string; branch: string | null; createdAt: Timestamp }
  export interface GitCommitRequest { message: string; amend?: boolean; expectedHead: string | null }
  export interface GitCommitResult { sha: string; output: string }          // output = 钩子与 git 的输出
  export interface GitStashRequest { message?: string; includeUntracked?: boolean }
  export interface GitStashApplyRequest { ref: string; drop: boolean }      // drop=true 即 pop
  // ErrorCode 新增：'GIT_UNAVAILABLE' | 'GIT_LOCKED' | 'GIT_HEAD_MOVED' | 'GIT_HOOK_FAILED' | 'GIT_CONFLICT' | 'GIT_FAILED' | 'FORBIDDEN_CLIENT'
  ```
  | 方法 | 路径 | 请求 | 响应 |
  | --- | --- | --- | --- |
  | GET | `/projects/:id/git/status` | – | `GitStatus` |
  | GET | `/projects/:id/git/diff?path=&staged=true\|false&context=3\|all` | – | `GitDiff`（未跟踪文件按全部新增显示；`context=all` 返回整个文件作为上下文，供差异窗口并排显示，仍受 5,000 行 / 2 MiB 上限） |
  | POST | `/projects/:id/git/stage` | `{ paths: string[] }` | `GitStatus` |
  | POST | `/projects/:id/git/unstage` | `{ paths: string[] }` | `GitStatus` |
  | POST | `/projects/:id/git/commit` | `GitCommitRequest` | `GitCommitResult` |
  | GET | `/projects/:id/git/stashes` | – | `GitStash[]` |
  | POST | `/projects/:id/git/stash` | `GitStashRequest` | `GitStatus` |
  | POST | `/projects/:id/git/stash/apply` | `GitStashApplyRequest` | `GitStatus` |
  - 语义：
    - 仓库 = 项目 `root` 的 `git rev-parse --show-toplevel`；所有路径参数必须位于该仓库内（拒绝 `..` 越界与绝对路径）。
    - daemon 调用本机 `git`（`-z` / porcelain v2 解析，`LC_ALL=C`，`GIT_TERMINAL_PROMPT=0`；只读查询带 `GIT_OPTIONAL_LOCKS=0`，避免与其他客户端争锁）。超时：查询 10 秒，提交 120 秒。
    - **写操作（stage / unstage / commit / stash / stash/apply）只接受 `X-DevPanel-Client: ui`**，其他客户端 → 403 `FORBIDDEN_CLIENT`。CLI 不提供 Git 命令。
    - `commit` 的 `expectedHead` 与当前 HEAD 不同 → 409 `GIT_HEAD_MOVED`（不提交）；钩子失败 → 422 `GIT_HOOK_FAILED`，`details.output`；`index.lock` 存在 → 409 `GIT_LOCKED`（不删除锁文件）；其他 git 错误 → 422 `GIT_FAILED`，`details.stderr`。
    - `stash/apply` 冲突 → 409 `GIT_CONFLICT`，`details.output`；冲突时即使 `drop=true` 也保留储藏。
    - 敏感文件名模式（`sensitiveName`）：文件名为 `.env`、`.env.*`（`.env.example` 除外）、`*.pem`、`*.key`、`*.p12`、`id_rsa*`、`id_ed25519*`、`credentials*`、`*.keystore`。只用于提示，daemon 不阻止提交。
    - 不提供丢弃改动、删除储藏、分支切换、远端操作。daemon 不常驻监听文件系统；状态只在请求时计算。
    - git 不存在 → 所有 Git 路由 503 `GIT_UNAVAILABLE`，`details.pathUsed`。
- 影响：后端新增 Git 模块与测试（用临时仓库，含钩子失败、锁、HEAD 移动、储藏冲突、越界路径）；原生程序新增 Git 摘要与 Git 页；mock 同步（可用内存中的假仓库）。
- 状态：已接受并生效（用户确认 plan-v0.3 第 2 稿的全部决定，2026-10-21），已写入 `api.md` §2、§9、§11、§12 与 `packages/contract`

### [已生效] 工具自身与辅助进程资源明细 — 提出方：backend — 2026-10-21
- 动机与授权：用户明确要求“整个工具，包括它的辅助进程的资源占用情况，最好也都能显示出来”。
- 差异：`DaemonInfo` 兼容新增可选 `toolResources`，包含 `daemon`、`helpers`、`total` 三个 ResourceSample；原有 self 只统计 daemon 的语义不变。具体完整性/缓存/口径见 api.md。
- 影响：原生客户端增加本地界面采样及合计明细；旧 daemon/mock 可省略字段，客户端显示部分可用。无新路由，无业务项目归属变化。
- 状态：用户已追认（2026-10-21）；前后端与 mock 同步完成。

### [已生效] macOS footprint 内存与低开销采样 — 提出方：backend — 2026-10-21
- 动机：用户提供的活动监视器对照证实 RSS 与 footprint 口径差；用户在说明性能取舍、保留显示并切换 footprint 的方案后回复“可以 那你去做一下优化吧”，确认实施。
- 差异：`ResourceSample`（及继承它的服务/项目统计）新增可选 `footprintBytes?: number | null`，单位 bytes，全部已核验进程成功读取才求和，否则 null/缺省；`rssBytes` 不改语义。项目按 PID+启动时间去重。具体语义同步 `api.md` §5 与共享类型。
- 影响：daemon 用 macOS 原生计数采样；原生客户端优先 footprint，缺失时明确 RSS 回退；旧客户端忽略新增字段、旧 daemon 和现有 mock 可缺省新字段，均保持兼容。没有改变路由或 API 主版本。
- 状态：用户已追认（2026-10-21）；仅更新代码与隔离测试，不重启用户真实服务。

### [已生效] v1.1-A 选项的几处细节澄清 — 提出方：frontend — 2026-10-20
- 动机：实现 mock-daemon 的 F0 时，以下几点契约没有写明，前后端可能各自取不同做法，原生程序需要按确定的规则显示和处理错误。mock 已按下列做法实现；类型无变化，只需在 `api.md` §3.1 补充文字。
- 变更（只是澄清）：
  1. **选项路由的错误码**：`PATCH` / `DELETE` 的 `:key` 不存在 → 404 `PARAM_UNKNOWN`。`POST` / `PATCH` 值不合法 → 422 `CONFIG_INVALID`，`details.issues` 中为 `PARAM_INVALID`（与注册 / 更新一致）。这三条路由只因选项相关的 error 拒绝保存，不因 `COMMAND_NOT_FOUND`、`CWD_UNAVAILABLE` 等与选项无关的问题拒绝（人改一个端口不应被 PATH 问题挡住）。`DELETE` 缺少 `ifRevision` → 400 `BAD_REQUEST`；`inline` 省略视为 `false`。
  2. **被保护的用户值与新定义不兼容**：`PUT` 时某选项 `setBy=user` 且请求值不同，但已存值在新定义下不合法（类型变了、不在新 `choices` 中、越过新 `min` / `max`）→ 422 `CONFIG_INVALID`（`PARAM_INVALID`，提示可传 `overrideUserValues`），不悄悄改用请求值。`POST /projects` 的幂等比较中这种情况按请求值比较（因此通常得到 409 `CONFIG_CONFLICT`）。
  3. **shell 转义的范围**：只转义紧跟在 `-c` / `-…c` 之后的那个脚本参数；脚本后面的位置参数（`$0`、`$1`…）本来就是独立 argv 元素，按普通参数替换，不加引号。
  4. **`RunDetail.params` 的范围**：只记录本服务实际引用的选项（命令 + 生效的环境变量，被服务覆盖的项目级环境变量不算），不是项目的全部选项。
  5. **占位符的识别**：只有 `${` + 合法 key + `}` 是占位符；`${a:-b}`、`${}`、未闭合的 `${` 按字面量处理。合法 key 形状但没有对应选项的（例如 shell 脚本里的 `${HOME}`）→ `PARAM_UNKNOWN`，需写成 `$${HOME}`。
  6. **写回（inline）**：写回的值中出现的 `${` 写成 `$${`，保证写回后的有效命令与删除前完全一致；写进 shell 脚本参数时按第 3 条加单引号。secret 选项写回环境变量时，该变量变为敏感值，内容为完整替换后的字符串（同一个值里引用的其他选项也一并写回）。
  7. **`WARN_SECRET_LIKE_PLAIN`**：名称像敏感值、但值只由 secret 选项的占位符组成（如 `HF_TOKEN: "${hfToken}"`）时不报这个警告。
- 影响：后端按上述规则实现或告知不同做法；前端原生程序按第 1 条处理错误提示，按第 4 条显示运行记录中的选项值。
- 状态：用户确认接受并生效（2026-10-20）；按用户指派由 backend 同步 api.md §3.1、共享类型注释及 daemon 实现/测试。

### [已生效] v1.1-A 选项（params）：AI 创建、人调整的配置项 — 提出方：frontend — 2026-10-20
- 动机：产品 v0.2 §4。profile、端口、监听地址等常改配置埋在长串命令里，人不好改也看不懂。由 AI 提炼成带说明的选项，命令通过占位符引用，启动时替换。
- 变更（全部为新增字段 / 新增路由，不改动已有字段语义）：

  **类型**
  ```ts
  export type ParamType = 'string' | 'number' | 'boolean' | 'enum';
  export type ParamSetter = 'agent' | 'user';
  export interface ParamChoice { value: string; label?: string; description?: string }

  export interface ParamConfig {
    key: string;                       // /^[a-zA-Z][a-zA-Z0-9_]{0,31}$/，项目内唯一
    label: string;
    type: ParamType;
    /** string/enum → string；number → number；boolean → boolean。
     *  secret 参数：请求中给 value 即设置；省略 value 表示保持原值；响应中永不返回 value。 */
    value?: string | number | boolean;
    description?: string;
    choices?: ParamChoice[];           // 仅 enum，至少 1 项；value 必须是其中之一
    min?: number; max?: number;        // 仅 number
    secret?: boolean;
    // —— 以下仅出现在响应中，请求中出现会被忽略 ——
    setBy?: ParamSetter;               // 当前值的最后设置者
    valueUpdatedAt?: Timestamp;
    describedBy?: ParamSetter;         // label / description / choices 的最后编辑者
    usedBy?: ParamReference[];
  }
  export interface ParamReference {
    serviceId: ServiceId;
    where: 'command' | 'env';
    index?: number;                    // where=command 时为 argv 下标
    envKey?: string;                   // where=env 时为变量名；项目级 env 时 serviceId 为 "*"
  }
  // ProjectConfig 新增：
  params?: ParamConfig[];
  // RunDetail 新增：本次运行实际使用的值（secret 为 { secret: true }）
  params: Record<string, string | number | boolean | { secret: true }>;
  // ErrorCode 新增：'PARAM_UNKNOWN' | 'PARAM_INVALID' | 'PARAM_IN_USE'
  // WarningCode 新增：'WARN_PARAM_UNUSED'
  ```

  **占位符与替换**
  - `${key}` 可出现在 `services[].command[*]` 和非敏感的环境变量值（项目级与服务级）中；`$${` 表示字面量 `${`。其他字段（cwd、name 等）不替换。
  - 引用不存在的 key → 校验 error `PARAM_UNKNOWN`；值不合类型 / 不在 choices / 越过 min、max → `PARAM_INVALID`；定义了但无人引用 → warning `WARN_PARAM_UNUSED`。
  - 替换在 **启动时** 用当时保存的值进行；数字转十进制字符串，布尔转 `true` / `false`；一个 argv 元素替换后仍是一个元素，不做分词。
  - 若 argv 是 shell 调用（`command[0]` 的文件名为 `sh` / `bash` / `zsh`，且后面某个参数为 `-c` 或以 `c` 结尾的短选项组如 `-lc`），则其后的脚本参数中的替换值按单引号规则转义。
  - `RunDetail.command` 返回替换后的 argv，其中来自 secret 参数的片段替换为 `••••`；`RunDetail.params` 记录实际值。
  - `configChangedSinceStart` 按替换后的有效命令与环境比较（沿用 v1.0 已生效的“按服务有效配置比较”规则），因此只改了未被某服务引用的选项，不会标记该服务。

  **设置者与覆盖保护**
  - 设置者由请求头 `X-DevPanel-Client` 决定：`ui` → `user`，`cli` → `agent`。
  - `PUT /projects/:id`（整份更新）与 `POST /projects`（已注册同根目录时的比较）中：若某选项已存的 `setBy = user`，且请求中的值不同，则 **保留已存的值**，除非请求体顶层带 `"overrideUserValues": true`。被保留的 key 在响应中列出：`PUT` 响应改为 `Project & { keptUserValues?: string[] }`（新增可选字段，向后兼容）。
  - 注册幂等比较时忽略 `setBy`、`valueUpdatedAt`、`describedBy`、`usedBy`。

  **给人用的细粒度路由**（UI 使用，避免整份提交覆盖他人改动）
  | 方法 | 路径 | 请求 | 响应 |
  | --- | --- | --- | --- |
  | POST | `/projects/:id/params` | `{ ifRevision, param: ParamConfig }` | `Project`；key 已存在 → 409 `CONFIG_CONFLICT` |
  | PATCH | `/projects/:id/params/:key` | `{ ifRevision, value?, label?, description?, choices?, min?, max? }` | `Project` |
  | DELETE | `/projects/:id/params/:key?ifRevision=N&inline=true\|false` | – | `Project` |
  - 删除时若被引用且 `inline=false` → 409 `PARAM_IN_USE`，`details.usedBy` 列出引用；`inline=true` → 把当前值写回每处引用后删除。secret 参数被命令引用时不允许 inline（会把秘密写进命令）→ 409 `PARAM_IN_USE`，`details.reason = "secret"`；被环境变量引用时写回为敏感环境变量。
  - 这些路由同样触发 `project.upsert` 事件，同样只影响下次启动。

  **CLI**
  ```bash
  devpanel param list <project-id> [--json]
  devpanel param set <project-id> <key> <value> [--if-revision <n>] [--json]
  devpanel param remove <project-id> <key> [--inline] [--if-revision <n>] [--json]
  ```
  CLI 发起的修改设置者为 `agent`。AI 创建选项走 `project register / update` 的配置文件。`devpanel project rules` 输出的 Agent 规则补充一句：“常改的配置请提炼为选项（params）并写明说明；不要覆盖用户改过的值。”
- 影响：
  - 后端：校验、存储、启动替换与转义、运行快照、设置者与覆盖保护、三条路由、CLI 子命令、测试。
  - 前端：原生程序的选项标签、编辑弹窗、选项列表、删除写回；mock-daemon 同步实现。
- 状态：已接受并生效（用户确认，2026-10-20），已写入 `api.md` 与 `packages/contract`

### [已生效] v1.1-B 受管进程真实监听的端口 — 提出方：frontend — 2026-10-20
- 动机：产品 v0.2 §5。总览需要显示服务实际开放的端口，并区分“仅本机 / 所有网卡”。
- 变更：
  ```ts
  export interface ListeningPort {
    port: number;
    address: string;                   // 例如 "127.0.0.1"、"0.0.0.0"、"::1"、"::"
    family: 'ipv4' | 'ipv6';
    scope: 'loopback' | 'all' | 'other';  // 127.0.0.0/8、::1 → loopback；0.0.0.0、:: → all
    pid: number;                       // 监听该端口的受管进程
  }
  // ServiceStats 新增：
  listening: ListeningPort[] | null;   // null = 本周期未能读取（权限 / 采集失败）；[] = 确认没有监听
  ```
  - 只读取已核验属于该运行的进程的 TCP LISTEN 套接字，不扫描、不归属任何非受管进程。
  - 同一 `port + address` 只出现一次。
  - 采集频率由后端决定，但不低于每 5 秒一次，且只在服务运行时采集；未采到前为 `null`。
  - 端口不作为进程归属依据（v0.1 §12.3 不变）。
- 影响：后端在资源采样中加入端口采集并写测试；前端在服务表和检查器显示；mock-daemon 同步。
- 状态：已接受并生效（用户确认，2026-10-20），已写入 `api.md` 与 `packages/contract`

<!-- 模板
### [提案] 简短标题 — 提出方：backend|frontend — 日期
- 动机：
- 变更：类型 / 路由 / 语义的具体差异
- 影响：另一方需要做什么
- 状态：待决 | 已接受 | 已拒绝
-->

### [已生效] `/config/validate` 接受“保持原值”的敏感值标记 — 提出方：frontend — 2026-10-20
- 动机：编辑已有项目时，UI 在字段失焦时调用 `POST /config/validate`。已保存的敏感值在表单里只有 `{secret:true}`（UI 拿不到明文，也不应回传）。§3 规定 `{secret:true}` “新键不允许”，但 validate 没有项目上下文，无法判断是否为新键，真实 daemon 可能因此报 error，导致编辑时出现假错误。
- 变更（已选方案 1）：`/config/validate` 对 `{secret:true}`（无 value）一律视为合法，不报 error；“新键不允许保持原值”只在注册 / 更新时检查。不增加 projectId 查询参数。
- 影响：后端区分独立校验与注册 / 更新时的敏感值检查；类型无变化。mock 已按方案 1 实现。
- 状态：已接受并生效（用户确认，2026-10-20）

### [已生效] 明确 `ServiceView.error` 与 `configChangedSinceStart` 的取值规则 — 提出方：frontend — 2026-10-20
- 动机：两个字段的语义有歧义，UI 需要按确定规则显示。
  - `error`：注释写“Why the service is 'failed' or 'unknown'”，但没有说明“启动成功后自行以非 0 退出”时填什么（ErrorCode 里没有对应码）。
  - `configChangedSinceStart`：注释写“Saved config revision differs from the currentRun's configRevision”。revision 是项目级的，改动一个服务会让所有运行中服务都显示“配置已修改”，与视觉稿（只标记被改的服务）不一致。
- 变更：
  - `error`：spawn 失败 / 启动期间退出 / 无法核验时填对应 ErrorCode；运行后自行退出时为 `null`，原因以 `lastRun.exit` 为准（UI 已按此回退显示“退出（1）”）。
  - `configChangedSinceStart`：按“该服务的有效配置（服务配置 + 项目级 env）与 currentRun 启动时的快照是否不同”计算，而不是比较项目 revision。
- 影响：后端按上述规则填值；类型不变，只更新注释与 api.md 文字。mock 已按此实现；UI 对两种取法都能显示，只是后一种会多标记。
- 状态：已接受并生效（用户确认，2026-10-20）

### [已生效] 停止超时的结果里附带进程数与等待秒数 — 提出方：frontend — 2026-10-20
- 动机：视觉稿的结果条写“已向 3 个受管进程发送 SIGTERM，10 秒内未全部退出”。`OperationTargetResult.error` 的 details 内容没有约定，UI 只能从 stats 或配置拼凑这两个数。
- 变更：outcome 为 `stop-timeout` 时，`error = { code: 'STOP_TIMEOUT', message, details: { timeoutSec: number, remaining: number } }`（`remaining` = 仍存活的已核验进程数）。
- 影响：后端在 stop-timeout 结果里填这两个 details 字段。UI 先读 details，缺失时回退到 stats.processCount 和配置的 `stopTimeoutSec`。
- 状态：已接受并生效（用户确认，2026-10-20）

### v1.0 — 2026-10-20
- 初版：`contract/api.md` + `packages/contract/src/index.ts`。
