# DevPanel 管理服务接口契约 v1

> 类型定义：`packages/contract/src/index.ts`（字段以它为准，本文说明语义）。
> 变更流程：只能通过 `contract/CHANGES.md` 提案，见 `AGENTS.md`。
> 产品语义来源：`docs/product-design-v0.1.md` §7–§12；v1.3 起见 `docs/product-design-v0.4.md`。

## 1. 进程与传输

| 项 | 约定 |
| --- | --- |
| 管理服务 | `devpaneld`（Node 24 + TypeScript，`packages/daemon`），单实例，独立于 UI 窗口与 CLI 调用存活 |
| 数据目录 `<home>` | 默认 `~/Library/Application Support/DevPanel`；环境变量 `DEVPANEL_HOME` 覆盖（测试与 mock 必须用它，不得碰真实目录）。目录权限 0700 |
| 发现文件 | `<home>/daemon.json`（0600），结构见 `DaemonDiscovery`。daemon 启动时写入、正常退出时删除 |
| CLI 通道 | Unix socket `<home>/run/devpanel.sock`（0600），HTTP/1.1 over socket，凭文件权限信任，不需要 token |
| UI 通道 | `127.0.0.1:<httpPort>`（默认 47823，`DEVPANEL_PORT` 覆盖），**只**绑定回环地址 |
| 两条通道 | 共用同一套路由与处理逻辑，行为完全一致 |
| 编码 | JSON UTF-8；时间 `Timestamp`（UTC ISO 毫秒）；字节为整数 |

### 1.1 HTTP 通道的安全要求

1. 认证：`Authorization: Bearer <token>`，或会话 Cookie `devpanel_session`（HttpOnly、SameSite=Strict、Path=/）。缺失或错误 → 401 `UNAUTHORIZED`。
2. Host 校验：`Host` 必须是 `127.0.0.1:<port>` 或 `localhost:<port>`，否则 403（防 DNS rebinding）。
3. Origin 校验：请求带 `Origin` 时必须等于 `http://127.0.0.1:<port>` 或 `http://localhost:<port>`，否则 403 `FORBIDDEN_ORIGIN`。不返回任何 CORS 允许头。
4. 所有非 GET 请求必须带 `X-DevPanel-Client: ui|cli`，否则 400 `BAD_REQUEST`（自定义头迫使跨站请求进入预检，从而被拒）。
5. 浏览器登录：`POST /api/v1/auth/ui-code`（仅 Unix socket 可调用）返回 `{ code, url }`，code 为一次性、60 秒有效。`GET /auth/exchange?code=…` 校验通过后设置会话 Cookie 并 302 到 `/`；code 用后即废。`devpanel open` 用这个流程打开浏览器。
6. 静态页面：`GET /` 及 `/assets/*` 提供 `apps/ui/dist`（路径可由 `DEVPANEL_UI_DIR` 指定），不需要认证（页面本身不含数据），但只有拿到 Cookie 后 API 才可用。
7. Agent 名称（v1.3-C）：请求可带 `X-DevPanel-Agent: <name>`（`/^[a-z0-9][a-z0-9._-]{0,31}$/`，不合法 → 400 `BAD_REQUEST`），仅对 `cli` 请求生效，`ui` 请求忽略。名称是自报的，只用于记录与显示（§15），不用于任何授权判断。

## 2. 资源与路由

所有路由前缀 `/api/v1`。成功返回 2xx + 正文；失败返回 4xx/5xx + `ErrorBody`。

| 方法 | 路径 | 请求 | 成功响应 | 说明 |
| --- | --- | --- | --- | --- |
| GET | `/daemon` | – | `DaemonInfo` | |
| POST | `/daemon/shutdown` | `ShutdownRequest` | 202 `Operation \| {}` | 有运行中服务且 `stopServices=false` → 409 `PROJECT_RUNNING`；`true` 时先停止全部服务（失败则不退出并返回结果）；停止绕过托管规则，不产生暂停，保留已有暂停与锁定，动态按请求方照常记录 |
| POST | `/config/validate` | `ProjectConfig` | `ValidateResult` | 只校验与解析，不保存、不执行 |
| GET | `/projects` | – | `ProjectView[]` | 注册顺序 |
| POST | `/projects` | `RegisterRequest` | 201/200 `RegisterResponse` | 见 §3 |
| GET | `/projects/:projectId` | – | `Project` | 配置（敏感值已遮盖） |
| PUT | `/projects/:projectId` | `UpdateRequest` | `UpdateResponse` | revision 不符 → 409 `REVISION_MISMATCH`（details 含当前 `revision`）；选项覆盖保护见 §3.1 |
| POST | `/projects/:projectId/params` | `AddParamRequest` | `Project` | v1.1-A；key 已存在 → 409 `CONFIG_CONFLICT` |
| PATCH | `/projects/:projectId/params/:key` | `PatchParamRequest` | `Project` | v1.1-A；只改出现的字段 |
| DELETE | `/projects/:projectId/params/:key` | `?ifRevision=N&inline=true\|false` | `Project` | v1.1-A；见 §3.1 删除 |
| DELETE | `/projects/:projectId` | – | 204 | 有服务处于 starting/running/stopping/unknown → 409 `PROJECT_RUNNING`。只删配置、运行记录与日志，不碰 `root` 下文件 |
| GET | `/projects/:projectId/view` | – | `ProjectView` | |
| GET | `/projects/:projectId/stats` | – | `ProjectStats` | 没有运行中服务时 `total.status='unavailable'`、`services={}` |
| GET | `/projects/:projectId/services/:serviceId/runs` | – | `RunSummary[]` | 新→旧，最多 `runsKeptPerService` 条 |
| GET | `/runs/:runId` | – | `RunDetail` | |
| GET | `/runs/:runId/logs` | `?before=&after=&limit=` | `LogPage` | 见 §6 |
| GET | `/runs/:runId/logs/stream` | `?afterSeq=` | SSE `LogStreamEvent` | 见 §6 |
| POST | `/operations` | `ActionRequest` | 202 `Operation` | 见 §4 |
| GET | `/operations/:operationId` | – | `Operation` | 结束后至少保留 10 分钟 |
| GET | `/operations/:operationId/wait` | `?timeoutMs=` (≤ 60000) | `Operation` | 长轮询：结束或超时即返回当前状态 |
| GET | `/events` | – | SSE `DaemonEvent` | 见 §7 |
| POST | `/projects/:projectId/actions/:actionId/runs` | – | 202 / 200 `StartTaskRunResponse` | v1.2-C，见 §11 |
| GET | `/projects/:projectId/actions/:actionId/runs` | – | `TaskRunSummary[]` | v1.2-C |
| GET | `/projects/:projectId/maven` | `?reload=1` | `MavenModel` | v1.2-C；无 pom → 404 `MAVEN_UNAVAILABLE` |
| POST | `/projects/:projectId/maven/runs` | `MavenRunRequest` | 202 `StartTaskRunResponse` | v1.2-C；忙 → 409 `TASK_RUNNING` |
| GET | `/projects/:projectId/maven/runs` | – | `TaskRunSummary[]` | v1.2-C |
| POST | `/task-runs/:runId/cancel` | `CancelTaskRunRequest` | 202 / 200 `TaskRunSummary` | v1.2-C |
| GET | `/task-runs/:runId` | – | `TaskRunDetail` | v1.2-C；日志用 `/runs/:runId/logs*` |
| GET | `/projects/:projectId/git/status` | – | `GitStatus` | v1.2-D，见 §12 |
| GET | `/projects/:projectId/git/diff` | `?path=&staged=true\|false&context=3\|all` | `GitDiff` | v1.2-D |
| POST | `/projects/:projectId/git/stage` / `unstage` | `GitPathsRequest` | `GitStatus` | v1.2-D；仅 `ui` 客户端 |
| POST | `/projects/:projectId/git/commit` | `GitCommitRequest` | `GitCommitResult` | v1.2-D；仅 `ui` 客户端 |
| GET | `/projects/:projectId/git/stashes` | – | `GitStash[]` | v1.2-D |
| POST | `/projects/:projectId/git/stash` | `GitStashRequest` | `GitStatus` | v1.2-D；仅 `ui` 客户端 |
| POST | `/projects/:projectId/git/stash/apply` | `GitStashApplyRequest` | `GitStatus` | v1.2-D；仅 `ui` 客户端 |
| GET | `/runs/:runId/ready/wait` | `?timeoutMs=` (≤ 60000) | `RunSummary` | v1.3-A，见 §13；任务运行 → 400 |
| GET | `/runs/:runId/digest` | `?afterSeq=&maxBytes=&tail=` | `LogDigest` | v1.3-B，见 §14；服务与任务运行通用 |
| GET | `/projects/:projectId/activity` | `?before=&limit=` | `ActivityPage` | v1.3-C，见 §15 |
| GET | `/projects/:projectId/policy` | – | `ProjectPolicy` | v1.3-D，见 §16 |
| PUT | `/projects/:projectId/policy` | `ProjectPolicy` | `ProjectPolicy` | v1.3-D；仅 `ui` 客户端 |
| DELETE | `/projects/:projectId/services/:serviceId/hold` | – | 204 | v1.3-D；仅 `ui` 客户端 |
| POST | `/auth/ui-code` | – | `{ code, url }` | 仅 Unix socket |

### 2.1 DaemonInfo（`GET /daemon`）

管理服务身份、版本、目录、限制和自身资源；字段定义见共享类型 `DaemonInfo`。

#### 工具自身资源

`DaemonInfo.toolResources?: { daemon: ResourceSample; helpers: ResourceSample; total: ResourceSample }` 为兼容新增字段。`self` 仍只表示管理进程，与 `toolResources.daemon` 相同。

- `daemon` 统计当前管理进程；`helpers` 统计其常驻原生采样辅助进程；`total` 为两者之和，绝不包含受管业务项目。macOS 的进程与端口采集共用该辅助进程，不再周期启动 ps/lsof。
- 后端每 2 秒采样并缓存，即使没有项目运行也继续；读取接口不触发额外系统采样。客户端自行采样当前界面进程，并与后端 `total` 合并，得到此实例的工具合计。
- 内存采用 `footprintBytes`，仅全部分项可用才能合计；不可将 RSS 与 footprint 相加。CPU 采用单核 100% 的区间使用率，初次采样为 null。
- 原生采样不可用时，`self` / `daemon` 可保留 Node CPU/RSS 回退；`helpers` 和 `total` 标为 unavailable、数值 null，附带原因，不把管理进程冒充全部后台。旧 daemon 缺省本字段时，客户端同样展示未知/部分可用。
- 客户端断线或采样超过 6 秒应标明过期，不把历史样本作为当前合计。启动瞬间的一次性编译/CLI 不属于稳定周期样本；本字段覆盖当前连接的后台与其持续工作的辅助进程。

## 3. 配置语义

- 注册与更新都先做与 `/config/validate` 相同的基础校验，并额外检查敏感值“保持原值”标记是否有对应的已保存敏感值；有 error 级 issue → 422 `CONFIG_INVALID`，`details.issues` 为 `ValidationIssue[]`。warning 不阻止保存。
- 校验内容：字段格式、服务 ID 唯一、`root` 是存在的绝对目录、`cwd` 解析后存在、`command` 非空、`command[0]` 能在有效 PATH 中解析（找不到 → error `COMMAND_NOT_FOUND`）。**不执行任何命令。**
- `root` 以 realpath 规范化后作为唯一键：
  - 未注册 → 201 `{created:true}`。
  - 已注册且配置等价（忽略敏感值的“保持不变”标记）→ 200 `{created:false}`，返回已有项目。
  - 已注册但配置不同 → 409 `CONFIG_CONFLICT`，`details: { projectId, revision, diff: ConfigDiffEntry[] }`。绝不静默覆盖。
- 更新是整份替换，但：请求里未出现的已有服务视为删除——为避免误删，删除正在运行的服务 → 409 `PROJECT_RUNNING`。
- 运行中更新配置只影响下次启动；当前运行保留原配置快照。`ServiceView.configChangedSinceStart` 不比较 `ready`（v1.3-A），其余按该服务的有效配置（服务配置 + 项目级 env）与 `currentRun` 启动时快照是否不同计算，不比较项目 revision；没有 `currentRun` 时为 false。环境按服务覆盖项目后比较，cwd 按解析后的绝对路径、停止超时按实际默认值比较。只改项目名、其他服务或被服务覆盖的项目 env 不标记本服务；恢复为启动时的有效配置后标记清除。保存配置永远不会触发启动或重启。
- 执行环境：`daemon 基础环境`（HOME、USER、LOGNAME、SHELL、TMPDIR、LANG、PATH）← `project.env` ← `service.env`，后者覆盖前者。基础 PATH 由 daemon 自身配置决定，并在 `ServiceResolution.pathUsed` 中如实返回；不随发起请求的终端变化。
- 敏感值：请求中 `{secret:true, value}` 设置；`{secret:true}` 表示保持原值。独立 `/config/validate` 无项目上下文，对合法的无 value 标记一律接受；注册 / 更新时才检查对应项目或同 ID 服务的同名键是否已有敏感值，新键不得保持原值。若独立校验的有效 PATH 也是无 value 标记，则无法解析裸程序名，`programResolved=null`、`pathUsed=""`，不因此报 `COMMAND_NOT_FOUND`；保存时使用实际值完整校验。响应中一律只返回 `{secret:true}`。敏感值不得出现在任何响应、事件、日志 `sys` 行或 CLI 输出里。存储文件权限 0600。

### 3.1 选项（params，v1.1-A）

- 定义见 `ParamConfig`。选项属于项目，任何服务都可以引用。
- **占位符**：只识别 `${` + 合法 key（`/^[a-zA-Z][a-zA-Z0-9_]{0,31}$/`）+ `}`。`${a:-b}`、`${}`、未闭合的 `${` 按字面量处理；合法 key 形状但未定义的（例如 `${HOME}`）返回 `PARAM_UNKNOWN`，字面量须写 `$${HOME}`。`${key}` 可出现在 `services[].command[*]` 和非敏感环境变量值（项目级与服务级）中，以及整值为 `"${key}"` 的 `services[].ready.check.port`（v1.3-A，只能引用 number 选项，`usedBy.where = 'ready'`）；`$${` 表示字面量 `${`。cwd、name 等其他字段不替换。
- **校验**：引用不存在的 key → error `PARAM_UNKNOWN`；key 格式、值类型、enum 值不在 `choices`、number 越过 `min` / `max` → error `PARAM_INVALID`；定义了但无人引用 → warning `WARN_PARAM_UNUSED`。独立 `/config/validate` 中没有 value 的 secret 选项视为合法（同敏感环境变量规则）。
- **替换时机**：只在启动时，用当时保存的值。数字转十进制字符串，布尔转 `true` / `false`。一个 argv 元素替换后仍是一个元素，不分词。
- **shell 转义**：若 `command[0]` 的文件名为 `sh` / `bash` / `zsh`，且其后某个参数为 `-c` 或以 `c` 结尾的短选项组（如 `-lc`），则只对紧跟该选项的一个脚本 argv 中的替换值按 POSIX 单引号规则转义，作为一个字面量。脚本后面的位置参数（`$0`、`$1`…）按普通 argv 替换，不额外加引号。
- **运行快照**：`RunDetail.command` 为替换后的 argv，来自 secret 选项的片段替换为 `••••`；`RunDetail.params` 只记录本服务实际引用的选项值（命令 + 生效的非敏感环境变量；secret 为 `{secret:true}`），被服务覆盖的项目级环境变量中的引用不计入，不记录项目的全部选项。
- **配置已修改**：`configChangedSinceStart` 按替换后的有效命令与环境比较，因此只改了某服务未引用的选项，不标记该服务。
- **设置者**：值发生变化时，按请求头 `X-DevPanel-Client` 记录 `setBy`（`ui` → `user`，`cli` → `agent`）并更新 `valueUpdatedAt`；label / description / choices / min / max 变化时记录 `describedBy`。`usedBy` 由 daemon 计算。
- **覆盖保护**：`PUT /projects/:id` 时，已存 `setBy = user` 的选项若请求中的值不同，保留已存值，除非请求带 `overrideUserValues: true`；被保留的 key 列在响应 `keptUserValues`。新增选项、删除选项、修改说明不受此保护。注册（`POST /projects`）的幂等比较忽略 `setBy`、`valueUpdatedAt`、`describedBy`、`usedBy`。
- **保护值与新定义不兼容**：`PUT` 保留的用户值若不符合新 type、choices 或 min/max，返回 422 `CONFIG_INVALID`，`details.issues` 中为 `PARAM_INVALID`，提示可显式传 `overrideUserValues`，不悄悄采用请求值。`POST /projects` 幂等比较中，该选项改用请求值比较（通常为 409 `CONFIG_CONFLICT`），不更新已存配置。
- **删除**：未被引用直接删除。被引用时：`inline=false` → 409 `PARAM_IN_USE`，`details.usedBy` 列出引用；`inline=true` → 把当前值写回每一处引用后删除。secret 选项被命令引用时拒绝写回（409 `PARAM_IN_USE`，`details.reason = "secret"`）；被环境变量引用时写回为敏感环境变量。写回普通值中的 `${` 存为 `$${`，确保下次启动的有效值不变；写回 shell 脚本时按上述脚本范围转义。secret 写回 env 时，整个环境变量完整替换为当前字符串（其中其他选项也一并写回），再转为敏感值。
- **选项路由校验与错误码**：`PATCH` / `DELETE` 的 key 不存在 → 404 `PARAM_UNKNOWN`；`POST` / `PATCH` 值不合法 → 422 `CONFIG_INVALID`，`details.issues` 中为 `PARAM_INVALID`。这三条路由只因选项相关 error 拒绝保存，不因 `COMMAND_NOT_FOUND`、`CWD_UNAVAILABLE` 等与选项无关的问题拒绝。`DELETE` 缺少 `ifRevision` → 400 `BAD_REQUEST`；`inline` 省略视为 `false`。
- **敏感名称警告**：环境变量名称像敏感值，但值只由 secret 选项占位符组成（如 `HF_TOKEN: "${hfToken}"`）时，不报 `WARN_SECRET_LIKE_PLAIN`；含普通文本或非敏感选项时仍按原规则提示。
- 选项路由与整份更新一样递增 revision、校验 `ifRevision`、触发 `project.upsert`，只影响下次启动。
- secret 选项的值遵循敏感值的全部规则（§3 最后一条）。

## 4. 操作语义（启动 / 停止 / 重启）

`POST /operations` 立即返回 202 和 `Operation`（`queued` 或 `running`）。HTTP 成功只代表“请求已接受”，最终结果看 `Operation.state` 与 `results`。

### 4.1 串行与幂等
- 每个服务一条串行队列。同一服务上的变更不会并发执行。
- `start`：服务已在 `starting/running` → 该目标 `already-running`，`runId` 为现有运行；**不会产生第二个实例**（UI 与 CLI 并发时也一样）。
- `stop`：服务未运行 → `already-stopped`。
- 服务处于 `unknown` 时 `start` → `failed` + `STATE_UNVERIFIABLE`，不启动（避免重复实例）；`stop` / `force-stop` 只对仍能核验身份的进程生效。

### 4.2 停止优先
- `stop` / `force-stop` 到达时，取消同一服务上所有排队中和执行中的 `start` / `restart`：被取消的目标 `outcome='cancelled'`，所属操作 `cancelledBy` 指向这次停止。被取消的启动若已经拉起进程，由这次停止负责停掉。
- 任何被取消的请求事后都不能再拉起服务。
- 被托管规则拒绝（`POLICY_DENIED`，§16）的 stop / force-stop 目标不参与停止优先：不取消同一服务排队中或执行中的启动 / 重启。

### 4.3 启动
1. 校验 cwd、程序可解析；失败 → `failed` + `CWD_UNAVAILABLE` / `COMMAND_NOT_FOUND`，并产生一个 `spawn-failed` 的运行记录（便于在 UI 看到原因）。
2. 以前台方式创建进程（独立会话 / 进程组），写入 `sys` 行“已启动 · 运行 … · PID … · 命令”。
3. 观察 `startGraceMs`（默认 1000ms）：期间退出 → `failed` + `EXITED_DURING_START`（退出码 0 也算，因为长期服务不应立刻结束；运行记录状态按退出码记为 exited/failed）。
4. 否则 → `started`，服务状态 `running`。不做任何健康检查；登记了就绪条件的服务另行判断就绪（§13），不影响操作结果与服务状态。
- 项目级 `start`：按配置顺序处理未运行的服务，不等待前一个“就绪”；某个失败不影响其他，不回滚已启动的服务；操作整体 `partial`。

### 4.4 停止
1. 向该运行拥有的进程范围（进程组 + 已核验的后代进程）发送 SIGTERM，写 `sys` 行。
2. 等待至 `stopTimeoutSec`。全部退出 → `stopped`。
3. 超时 → 目标 `stop-timeout`，`error = { code: 'STOP_TIMEOUT', message, details: { timeoutSec: number, remaining: number } }`。`timeoutSec` 为本次停止实际采用的等待秒数，`remaining` 为超时时仍存活的已核验进程数（不是最初发送信号的进程数，也不取缓存 stats）。服务保持 `stopping` 且 `stopTimedOut=true`；进程继续被跟踪，之后若自行退出，服务转 `stopped`。
4. `force-stop`：向仍存活的已核验进程发送 SIGKILL，等待确认退出。
- 只对“可核验属于本次运行”的进程（pid + 启动时间一致）发信号。绝不按名字、按端口杀进程。

### 4.5 重启
- 等价于对每个目标执行 stop → start；stop 未确认完成（超时或失败）→ 该目标 `failed` + `STOP_TIMEOUT`，**不启动新进程**；停止超时时保留同样的 `details.timeoutSec` 和 `details.remaining`。
- 新运行有新的 `RunId`。

### 4.6 状态迁移

```
idle ──start──▶ starting ──grace ok──▶ running ──stop──▶ stopping ──exit──▶ stopped
                    │                     │                  │
                    │ spawn 失败/早退       │ 自行退出           └─timeout─▶ stopping(stopTimedOut) ──force/exit──▶ stopped
                    ▼                     ▼
                 failed          exited(code 0) / failed(非 0 或信号)
任一状态 ──无法核验──▶ unknown
```

`ServiceView.error`：spawn 失败（含 cwd / 程序解析失败）、启动观察期内退出、无法核验时填对应 ErrorCode。启动成功后自行退出（包括非 0 退出码或信号）时为 `null`，退出原因以 `lastRun.exit` 为准。停止超时期间填 `STOP_TIMEOUT`；确认停止后清除。

## 5. 资源采样

- 仅在存在运行中服务时采样，周期 `statsIntervalMs`（默认 2000）。所有客户端共享同一份结果（`stats` 事件 / `GET …/stats`），不会因为多开窗口而多采样。
- 范围：运行的根进程 + 已核验的后代进程，持续发现新子进程；离开进程组但仍是后代的进程继续计入。
- CPU：相邻两次采样的 CPU 时间差 / 墙钟时间差 × 100，求和，不截断。首次采样 `status='sampling'`、`cpuPercent=null`。
- 内存：`rssBytes` 仍为 RSS 求和，语义不变。项目 `total` 按进程身份去重后求和。
- **macOS 内存占用（2026-10-21）**：新增可选 `footprintBytes: number | null`，单位 bytes，为该运行全部已核验进程的 `ri_phys_footprint` 之和（项目 total 同样按身份去重）；含系统计账的压缩/换出内存，不等于 JVM 堆、RSS 或全机物理页去重后的净占用。全部读取成功才返回数值，任一读取失败、不支持或不可用时为 `null`，旧服务端可缺省；绝不将部分 footprint 合计伪装成完整值。首次 CPU 采样中也可返回已取得的内存。
- macOS 客户端优先显示 footprint；缺省/null 时允许退回 RSS，但必须明确标注 RSS。保留已有 `statsIntervalMs` 采样/广播周期和进程归属规则，不为每个客户端重复采样。
- 读取失败的进程 → `partial` + `note`；全部失败 → `unavailable`。**绝不用 0 代替未知。**
- **监听端口（v1.1-B）**：`ServiceStats.listening` 为该运行已核验进程的 TCP LISTEN 套接字（`ListeningPort`），同一 `port + address` 只出现一次。只在服务运行时读取，频率由后端决定但不低于每 5 秒一次；本周期未能读取为 `null`，确认没有为 `[]`。不扫描、不归属任何非受管进程；端口不作为进程归属或停止依据。

## 6. 日志

### 6.1 采集
- 来源：受管进程的 stdout（`out`）、stderr（`err`），以及 daemon 插入的 `sys` 行。
- 合并顺序为采集顺序；`seq` 每运行从 1 开始严格递增。
- 单行超过 `logLineMaxBytes` 拆分，前段 `partial=true`。
- 采集绝不阻塞业务进程的输出。采集中断（例如管道异常）要写入 `gap` 事件和 `sys` 行。

### 6.2 上限（默认值，`DaemonInfo.limits` 返回实际值）

| 限额 | 默认 |
| --- | --- |
| `logBytesPerRun` | 32 MiB（超出丢弃最旧部分，`truncated=true`） |
| `runsKeptPerService` | 3（含当前运行；更旧的运行连同日志删除） |
| `logBytesGlobal` | 1 GiB（超出时从最旧的非当前运行开始删除） |
| `logLineMaxBytes` | 64 KiB |
| `logPageMaxLines` | 2000（单次 `GET …/logs` 上限） |

### 6.3 分页 `GET /runs/:runId/logs`
- 无参数：返回最新的 `limit`（默认 500，最大 `logPageMaxLines`）行。
- `before=N`：返回 `seq < N` 的最近 `limit` 行（向上翻页）。
- `after=N`：返回 `seq > N` 的最早 `limit` 行。
- 运行已结束仍可读取，直到被保留策略删除（→ 404 `RUN_NOT_FOUND`）。

### 6.4 实时流 `GET /runs/:runId/logs/stream?afterSeq=N`
- 先补发 `seq > N` 的已有行（若 N 已被截断，先发 `truncated` 再从 `firstSeq` 发），然后实时推送。
- `lines` 事件批量发送（≤ 100ms 合并一次，每批 ≤ 500 行）。
- 运行结束且日志全部送达后发 `end`，然后关闭流。`end.run` 为 `RunSummary | TaskRunSummary`：服务返回服务摘要，快捷操作 / Maven 返回真实任务摘要（含 `kind`、任务终态），不投影为服务；客户端按 `runId` 与 `endedAt` 关闭订阅。
- 每 10 秒 `ping`。
- 客户端慢时 daemon 可以丢弃该连接的待发数据并发 `gap`，但不得影响采集与其他连接。

## 7. 全局事件流 `GET /events`

- 连接后立刻发送 `snapshot`（全量）。之后：
  - 任一服务状态 / 项目配置变化 → `project.upsert`（完整的 `ProjectView`）；
  - 项目移除 → `project.remove`；
  - 操作状态变化 → `operation`；
  - 每个采样周期 → `stats`；
  - 每 10 秒 `ping`。
- 不提供断点续传：客户端重连后以新的 `snapshot` 全量替换本地状态。
- UI 用 `fetch` + 流式读取（可带 Authorization 头），浏览器模式下靠 Cookie；两者都必须支持。

## 8. daemon 重启与身份核验

- 运行记录持久化 pid、进程启动时间、进程组。daemon 启动时逐一核验：
  - 进程仍在且身份一致、日志采集能接续 → 恢复为 `running`；
  - 进程已不在 → 运行以 `daemon-lost` 结束，服务转 `stopped/failed`（按可知信息），并写 `sys` 行；
  - 进程在但无法确认归属或无法接续日志 → 服务 `unknown` + `STATE_UNVERIFIABLE`，阻止重复启动，允许对仍可核验的进程停止。
- 系统重启后：配置与历史日志保留，所有服务 `stopped`/`idle`，不自动启动。

## 9. CLI 契约（`packages/cli`，命令 `devpanel`）

CLI 只是客户端：所有动作都走 Unix socket，不自己执行项目命令。

```bash
devpanel daemon start|stop|status            # stop 等价 POST /daemon/shutdown；有运行中服务时需 --stop-services
devpanel open                                # 获取一次性 code，用默认浏览器打开面板
devpanel project register --config <file> [--json]
devpanel project update <project-id> --config <file> --if-revision <n> [--json]
devpanel project show <project-id> [--json]
devpanel project list [--json]
devpanel project remove <project-id> [--json]
devpanel project validate --config <file> [--json]
devpanel project rules <project-id>          # 输出 Agent 规则文本（含真实项目 ID）
devpanel status [<project-id>] [--json]
devpanel start|stop|restart|force-stop <project-id> [--service <id>]... [--no-wait] [--timeout <sec>] [--json]
devpanel operation <operation-id> [--json]
devpanel logs <project-id> --service <id> [--run <run-id>] [--tail <n>] [--follow]
devpanel stats <project-id> [--json]
devpanel param list <project-id> [--json]                                    # v1.1-A
devpanel param set <project-id> <key> <value> [--if-revision <n>] [--json]   # 设置者为 agent
devpanel param remove <project-id> <key> [--inline] [--if-revision <n>] [--json]
devpanel action list <project-id> [--json]                                                     # v1.2-C
devpanel action run <project-id> <action-id> [--no-wait] [--follow] [--timeout <sec>] [--json]
devpanel maven modules <project-id> [--json]
devpanel maven run <project-id> [--module <id>] [-P <p>]... [--skip-tests] [--offline] [--also-make] <goal>... [--no-wait] [--follow] [--json]
devpanel task cancel <run-id> [--force] [--json]
devpanel logs <project-id> --run <run-id> [--tail <n>] [--follow]                               # 也接受任务运行 ID
devpanel start|restart <project-id> [--service <id>]... --wait-ready [--ready-timeout <sec>] [--override-hold] [--json]   # v1.3-A / v1.3-D
devpanel logs <project-id> (--service <id> | --run <run-id>) --after-seq <n> [--tail <n>]        # v1.3-B，对应 GET …/logs?after=n
devpanel logs <project-id> (--service <id> | --run <run-id>) --digest [--after-seq <n>] [--max-bytes <n>] [--json]
devpanel activity <project-id> [--limit <n>] [--json]                                            # v1.3-C
devpanel policy <project-id> [--json]                                                            # v1.3-D，只读
devpanel --agent <name> …                                                                         # v1.3-C，全局参数；或环境变量 DEVPANEL_AGENT
```

- 定位只用 ID；项目名永远不作为参数。单服务项目可省略 `--service`。
- `param set` 的 `<value>` 按选项类型解析（number 解析为数字，boolean 只接受 `true` / `false`），不合法 → `PARAM_INVALID`，退出码 2。`project rules` 输出的 Agent 规则包含：“常改的配置请提炼为选项（params）并写明说明；不要覆盖用户改过的值。”
- 控制命令默认等待操作结束（用 `/operations/:id/wait` 循环，默认总超时 60s）；`--no-wait` 立刻返回 202 时的 `Operation`。等待超时返回当前状态并退出码 8，不代表失败或成功。
- `--json` 输出：成功时为响应对象本身；失败时为 `ErrorBody`。stdout 只输出结果，提示信息走 stderr。
- v1.3：`--agent <name>`（优先）或 `DEVPANEL_AGENT` 有值时，CLI 的所有请求附带 `X-DevPanel-Agent`；不合法 → 退出码 2；CLI 不推断名称。`--wait-ready --json` 时 stdout 始终为 `CliStartReport`（成功、失败都是），不输出 `ErrorBody`；daemon 不可达等请求前失败仍为 `ErrorBody`。
- daemon 不可达：输出 `DAEMON_UNREACHABLE`，提示运行 `devpanel daemon start`；**不**自动启动项目，也不回退到其他方式运行。

退出码：

| 码 | 含义 |
| --- | --- |
| 0 | 成功（操作 `succeeded`；查询成功） |
| 1 | 操作 `failed` 或其他错误 |
| 2 | 用法错误 / `BAD_REQUEST` / `CONFIG_INVALID` |
| 3 | `DAEMON_UNREACHABLE` |
| 4 | `*_NOT_FOUND` |
| 5 | `CONFIG_CONFLICT` / `REVISION_MISMATCH` / `PROJECT_RUNNING` |
| 6 | 操作 `partial` |
| 7 | `STOP_TIMEOUT` / 目标 `stop-timeout` |
| 8 | 等待超时，操作仍在进行 |
| 9 | 操作被取消（`cancelled`，例如用户在面板点了停止） |
| 10 | 任务运行超时（`timed-out`，v1.2-C） |
| 11 | 就绪超时：`--wait-ready` 时有目标 `ready.state = 'timed-out'`（v1.3-A） |
| 12 | 操作中失败的目标全部为 `POLICY_DENIED`（v1.3-D）；与其他失败混合时按 6 / 1 |

## 10. 示例

```jsonc
// POST /api/v1/operations   X-DevPanel-Client: cli
{ "projectId": "p_7k2m9q4tza", "action": "start" }

// 202
{ "id": "op_01JC8ZB3F8W6", "projectId": "p_7k2m9q4tza", "action": "start",
  "serviceIds": ["backend", "frontend"], "source": "cli", "state": "running",
  "createdAt": "2026-10-20T02:42:06.002Z", "finishedAt": null, "cancelledBy": null,
  "results": [
    { "serviceId": "backend",  "outcome": "pending", "runId": null, "error": null },
    { "serviceId": "frontend", "outcome": "pending", "runId": null, "error": null } ] }

// GET /api/v1/operations/op_01JC8ZB3F8W6/wait  → 结束
{ "...": "...", "state": "partial", "finishedAt": "2026-10-20T02:42:07.210Z",
  "results": [
    { "serviceId": "backend",  "outcome": "started", "runId": "r_01JC8ZB3P1", "error": null },
    { "serviceId": "frontend", "outcome": "failed",  "runId": "r_01JC8ZB3P2",
      "error": { "code": "COMMAND_NOT_FOUND", "message": "在 PATH 中找不到 pnpm",
                 "details": { "program": "pnpm", "pathUsed": "/usr/bin:/bin:/usr/sbin:/sbin" } } } ] }
```

## 11. 快捷操作与 Maven（v1.2-C）

### 11.1 任务运行（共用）
- 快捷操作与 Maven 的运行统称“任务运行”（`TaskRunSummary`），运行到结束：退出码 0 → `succeeded`，非 0 或信号 → `failed`。
- 进程托管与服务完全相同：独立进程组、pid + 启动时间核验、子进程跟踪、日志采集与上限（单次 `logBytesPerTaskRun`）、资源采样（`ProjectStats.tasks`，并计入项目 `total`）。
- 取消：`POST /task-runs/:runId/cancel` 向已核验进程发 SIGTERM，状态 `cancelling`；超过 `stopTimeoutSec`（Maven 用 `defaultStopTimeoutSec`）仍未退出时 `cancelTimedOut = true`；`force: true` 发 SIGKILL。结束后 `cancelled`。对已结束的运行返回 200 原样。
- 超时：超过 `timeoutSec` 按取消处理，结束后 `timed-out`，`exit.reason = 'timeout'`。
- 保留：每个快捷操作、以及每个项目的 Maven 各保留最近 `taskRunsKept` 次运行及其日志。
- daemon 重启：与服务相同的核验规则；可核验的继续跟踪，无法核验 → `unknown`，已消失 → `failed` + `daemon-lost`。**不自动重跑**。
- 注册 / 更新 / 校验不执行任何任务运行；删除运行中的快捷操作、或有任务运行中的项目 → 409 `TASK_RUNNING`。
- 变化通过 `project.upsert`（`ProjectView.actions` / `ProjectView.maven`）推送，不新增事件类型。日志使用 `/runs/:runId/logs` 与 `/runs/:runId/logs/stream`（RunId 与服务运行共用命名空间）。

- `ActionView.lastRun` 与 `ProjectView.maven.lastRun` 均为最近一次已结束的任务运行（没有则 null），运行中的记录只放 `currentRun`；开始新运行时保留上次结果。

### 11.2 快捷操作
- 配置：`ProjectConfig.actions`（`ActionConfig`），校验规则同服务（ID 格式与唯一性、cwd、程序可解析、`${key}` 选项引用）；`usedBy` 中以 `serviceId = "action:<actionId>"` 表示引用。
- 同一快捷操作同时最多一个运行：再次运行返回 200 `{ created: false, run: <现有运行> }`；不同快捷操作可并行。
- `confirmWhenServicesRunning` 只供客户端确认，daemon 不阻止。

### 11.3 Maven
- 模型：`GET /projects/:id/maven` 从项目根 `pom.xml` 起按 `<modules>` 递归**静态解析** XML（坐标、`<name>`、`<packaging>`、`<profiles>`、`<parent>`），不运行 Maven、不联网、不读 `~/.m2`；按各 `pom.xml` 修改时间缓存，`reload=1` 强制重新解析。单个 POM 解析失败只影响该模块（`error`）。
- 可执行文件：`ProjectConfig.maven.executable`，`auto`（缺省）= 项目根存在可执行的 `mvnw` 时用它，否则在有效 PATH 中解析 `mvn`；找不到 → 422 `COMMAND_NOT_FOUND`。
- 命令构造（只由 daemon 构造，不接受任意参数）：`<mvnw|mvn> [-pl <moduleId> [-am]] [-DskipTests] [-o] [-P<p1,p2>] <goals...>`，`moduleId = "."` 时不加 `-pl/-am`；在项目根执行；环境为项目级 env 的有效值。
- 校验：`moduleId` 必须是当前模型中的模块；`goals` 非空且每项匹配 `^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+){0,3}(@[A-Za-z0-9_.-]+)?$` 且不得以 `-` 开头（如 `-o`、`--help`）；拒绝未知请求字段；`profiles` 每项匹配 `^!?[A-Za-z0-9_.-]+$`；否则 422 `MAVEN_INVALID`（`details` 指明字段）。
- 同一项目同一时刻最多一个 Maven 运行：已有时 409 `TASK_RUNNING`，`details.runId`。`label` 由 daemon 生成，例如 `clean install · backend`。

## 12. Git（v1.2-D）
- 仓库 = 项目 `root` 的 `git rev-parse --show-toplevel`；不是仓库时 `GitStatus.repo = null`（其余 Git 路由 → 422 `GIT_FAILED`，`details.reason = "not-a-repository"`）。git 不存在 → 503 `GIT_UNAVAILABLE`，`details.pathUsed`。
- daemon 用本机 `git` 执行：porcelain v2 与 `-z` 解析，`LC_ALL=C`、`GIT_TERMINAL_PROMPT=0`；只读查询带 `GIT_OPTIONAL_LOCKS=0`。超时：查询 10 秒，提交 120 秒。
- 路径参数必须是仓库内的相对路径；绝对路径、`..` 越界、指向仓库外的符号链接 → 400 `BAD_REQUEST`。
- **写操作**（stage、unstage、commit、stash、stash/apply）只接受 `X-DevPanel-Client: ui`，其他 → 403 `FORBIDDEN_CLIENT`。CLI 不提供 Git 命令。
- `status`：分组信息见 `GitEntry`；超过 5,000 条截断；`ahead / behind` 无上游时为 0。
- `diff`：`staged=true` 比较 HEAD 与暂存区，`false` 比较暂存区与工作区；未跟踪文件按全部新增；`context` 为上下文行数（缺省 3，最大 1,000）或 `all`（整个文件，供并排显示）；超过 5,000 行或 2 MiB → `truncated = true`；二进制 → `binary = true`、`hunks = []`、给出 `oldSize / newSize`。
- `commit`：`expectedHead` 与当前 HEAD 不同 → 409 `GIT_HEAD_MOVED`（不提交）；钩子失败 → 422 `GIT_HOOK_FAILED`，`details.output`；`index.lock` 存在 → 409 `GIT_LOCKED`（不删除锁文件）；其他 → 422 `GIT_FAILED`，`details.stderr`。仓库钩子照常执行。
- `stash/apply`：冲突 → 409 `GIT_CONFLICT`，`details.output`，且保留储藏（即使 `drop = true`）。
- 敏感文件名（`GitEntry.sensitiveName`）：文件名为 `.env`、`.env.*`（`.env.example`、`.env.sample` 除外）、`*.pem`、`*.key`、`*.p12`、`*.keystore`、`id_rsa*`、`id_ed25519*`、`credentials*`。只用于提示，daemon 不阻止。
- 不提供：丢弃改动、删除储藏、分支切换、远端操作。daemon 不常驻监听文件系统，状态只在请求时计算。

- `GitDiff.baseOid` / `newOid`：必填 `string | null`，Git blob oid（仓库对象格式，SHA-1 或 SHA-256）。已暂存侧为 HEAD / index，未暂存侧为 index / 工作区原始内容（不运行过滤器、不写入对象）；符号链接按链接文本计算。不存在或未合并的侧为 null。覆盖完整内容，包含二进制与截断部分；客户端比较两侧指纹检测变化。

## 13. 就绪（v1.3-A）

- 就绪 = 服务可以接受请求的一个可观察信号，**不是**健康检查：只判断一次，就绪后不再检查；不发 HTTP 请求。服务状态（§4.6）与操作结果不受就绪影响。
- 配置：`ServiceConfig.ready`（`ReadyConfig`）。
  - `log`：`contains` 1–5 项，每项 1–200 字符；对本次运行 `out` / `err` 行（不含 `sys`）去掉 ANSI 后做区分大小写的子串匹配，任一命中即就绪；不支持正则。
  - `port`：本次运行已核验进程出现 TCP LISTEN；省略 `port` 表示任意端口；数字 1–65535，或整值 `"${key}"` 引用非敏感 number 选项（启动时替换）；引用 secret 选项 → `PARAM_INVALID`。`inline=true` 删除被就绪端口引用的选项时，将当前值写回为 JSON number，不能写成数字字符串。
  - `timeoutSec` 默认 120，1–900。
  - 不合法 → `CONFIG_INVALID`（选项引用沿用 `PARAM_UNKNOWN` / `PARAM_INVALID`）。注册 / 校验不执行任何命令。
- 运行：启动时快照就绪条件，每次运行独立判断，结果在 `RunSummary.ready`（`ReadyInfo`）。
  - 无就绪条件 → `not-configured`；有 → `waiting`，之后进入 `ready`（记录 `at`、相对 `startedAt` 的 `afterMs`、`evidence`）、`timed-out` 或 `ended-before-ready`（含 spawn 失败与启动观察期退出）。这三个为终态。
  - 日志从 seq 1 起扫描。端口在 `waiting` 期间至少每秒读取一次该运行已核验进程的监听套接字（与 §5 同一采集方式），离开 `waiting` 后不再额外读取。
  - 超时只做标记：不发信号、不改服务状态、不重启。
  - 状态变化通过 `project.upsert`（`currentRun.ready` / `lastRun.ready`）推送，不新增事件类型。
  - 旧运行记录读出为 `{ state: 'not-configured', at: null, afterMs: null, evidence: null }`。v1.3 daemon 必须返回 `ready`；类型上可选只为兼容旧 daemon。
- daemon 重启：`waiting` 的运行若按 §8 恢复且日志能续接，从已处理的 seq 之后继续判断，等待上限仍从 `startedAt` 起算；否则 → `unknown`。
- `GET /runs/:runId/ready/wait?timeoutMs=`（≤ 60000）：`ready.state` 离开 `waiting` 或长轮询到期即返回当前 `RunSummary`；任务运行 → 400 `BAD_REQUEST`（`details.reason = "task-run"`）。
- CLI `--wait-ready`：先按 §9 等操作结束，再对 outcome 为 `started` / `already-running` 的目标调用 `ready/wait`，直到离开 `waiting`。
  - `--ready-timeout` 只限制 CLI 等待，不改变 daemon 的判断；CLI 等待到期 → 退出码 8。
  - 输出 `CliStartReport`；`ended-before-ready` / `timed-out` / `failed` 的目标附 `digest`（§14）。
  - 退出码：操作本身非 0（1 / 5 / 6 / 7 / 9 / 12）照旧；否则有 `ended-before-ready` → 1，有 `timed-out` → 11，其余 → 0。`not-configured` 视为 0，并在 stderr 提示自行确认或补登记就绪条件。

## 14. 日志摘要（v1.3-B）

`GET /runs/:runId/digest?afterSeq=&maxBytes=&tail=` 对一次运行（服务或任务）的日志做确定性压缩，返回 `LogDigest`。参数：`maxBytes` 默认 8192（1024–65536），`tail` 默认 20（0–200），`afterSeq` 省略表示从最早保留的行开始。只读，按请求计算，不缓存、不常驻分析；不调用模型，不解释原因。

- **错误标题行**：去掉 ANSI 后满足任一条件。只因 `stream = err` 不算。
  - (a) 含区分大小写的独立大写单词 `ERROR` / `FATAL` / `SEVERE`；
  - (b) 匹配 `^\s*[A-Za-z_$][\w$.]*(Exception|Error)(: |$)`；
  - (c) 以 `Traceback (most recent call last):` 或 `panic:` 开头。
- **错误块** = 标题行 + 紧随其后的堆栈行，遇到第一条非堆栈行结束。堆栈行包括：`^\s+at `、`^\s*(Caused by|Suppressed): `、`^\s+\.\.\. \d+ (more|common frames omitted)`、`^\s+File "`，以及 Python Traceback 内缩进的代码行。以 `Traceback (most recent call last):` 开头的块还包含堆栈之后紧接的第一条非缩进行（异常行），并在该行结束。
- **折叠**：保留标题、前 5 个 `at` 帧、每个 `Caused by` / `Suppressed` 行及其后 2 帧，其余以 `folded` 表示。原生程序的日志折叠使用同一规则。
- **签名去重**：标题文字中连续数字替换为 `#` 后作为签名；Python Traceback 使用块末异常行作为签名，没有异常行时仍用标题行；同签名的错误块只保留第一次，`occurrences` / `lastOccurrenceSeq` 记录次数与最后一次。连续完全相同的行合并，`repeat` 记录行数。单行超过 1 KiB 截断并以 `…` 结尾。
- **预算**：按序列化后的 `blocks` 字节计。依次放入第一个错误块、时间上最后出现的错误块（`lastOccurrenceSeq` 最大者）、tail（最后 `tail` 行，同样折叠与合并），再按时间补其余错误块；放不下的计入 `omitted`；单块超出剩余预算时截取前部并计入 `omitted.bytes`。范围内或之前有内容被 §6.2 上限丢弃时 `truncated = true`。
- **文本格式**（CLI 非 `--json` 输出与原生程序“复制摘要”一致）：
  ```text
  [digest r_01JC… · 行 1–3204 · 错误块 2，省略 0 · 省略 0 字节]
  ── ERROR ×50 · 行 812，最后 3101 ──
  812 E java.lang.IllegalStateException: Failed to bind port 8080
  813 E     at org.example.Server.start(Server.java:42)
        … 省略 37 行堆栈
  ── 末尾 20 行 ──
  3185 O Shutting down  ×3
  ```
  每行为 `seq`、流标记（`O` / `E` / `S`）、文字；`repeat ≥ 2` 时行尾加 `  ×N`；`truncated` 时首行之后加 `[较早的日志已被上限丢弃]`。
- CLI：`--digest` 输出摘要；`--after-seq <n>` 在普通日志中对应 `GET …/logs?after=n`，在摘要中对应 `afterSeq`。

## 15. 操作来源与动态（v1.3-C）

- **发起方** `Actor = { client, agent }`：`client` 取自 `X-DevPanel-Client`（daemon 自身为 `daemon`）；`agent` 取自 `X-DevPanel-Agent`，仅 `cli` 请求有值。记录位置：
  - `Operation.actor`（`source` 保留，恒等于 `actor.client`）；
  - `RunSummary.startedBy`、`TaskRunSummary.startedBy`：发起这次启动的操作或请求的一方；
  - `ExitInfo.requestedBy`：`user-stop` / `force-stop` / `start-cancelled` 时为发起停止的一方；任务运行被取消时为取消方；其他原因为 `null`。

  v1.3 daemon 必须返回这些字段，旧记录为 `null`。选项的 `setBy` 语义不变。
- **动态** `GET /projects/:projectId/activity?before=<id>&limit=`：默认 50，≤ 200，新 → 旧，返回 `ActivityPage`。
  - 写入时机：
    - operation 到达终态时写一条 `operation`；
    - 注册、更新、选项路由保存成功时写一条 `config`（`change` 为 register / update / param，register 的 `fromRevision = 0`；幂等注册 `created:false` 不写）。`changes` 用 `ConfigDiffEntry`，最多 100 条，敏感值一律为 `{ secret: true }`；
    - 任务运行结束时写一条 `task-run`；
    - 托管规则变化写 `policy`（§16）。
  - 每项目保留最近 `limits.activityKeptPerProject`（默认 500）条，超出删最旧；删除项目时一并删除。
  - 不新增事件类型：客户端在动态可见时，收到 `operation` / `project.upsert` 后重新读取。
  - 只记录，不提供回滚。

## 16. 托管规则（v1.3-D）

- `ProjectPolicy`：`holdAfterUserStop`（默认 `true`）、`agentForceStop`（默认 `'deny'`）、`lockedServices`（默认 `[]`）。
  - 规则不属于 `ProjectConfig`：注册 / 更新 / 校验不读取也不写入；新项目使用默认值。
  - 更新配置删除服务时，自动从 `lockedServices` 移除。
  - `ProjectView.policy`、`ServiceView.hold` / `locked` 反映当前状态；变化触发 `project.upsert`。
- 修改：`PUT /projects/:id/policy`、`DELETE /projects/:id/services/:serviceId/hold` 只接受 `X-DevPanel-Client: ui`，其他 → 403 `FORBIDDEN_CLIENT`。`lockedServices` 含不存在的服务 → 422 `CONFIG_INVALID`。CLI 只提供只读的 `devpanel policy`。
- **产生暂停**：`holdAfterUserStop = true` 时，`ui` 发起的 stop / force-stop（服务级或项目级）中 outcome 为 `stopped` / `stop-timeout` 的目标进入暂停（`ServiceHold`）；已在暂停中的保留原 `since`。
- **解除暂停**：以下任一情况都会解除。暂停会持久化，daemon 重启后保留。
  - `ui` 的 start / restart 使该目标 outcome 为 `started` / `already-running`；
  - `DELETE …/hold`；
  - `cli` 带 `overrideHold: true` 的 start / restart 成功启动；
  - `holdAfterUserStop` 被改为 `false`：清除该项目全部暂停。
- **拒绝**：以下 `cli` 目标的 outcome 为 `failed`，`error = { code: 'POLICY_DENIED', details: { reason, serviceId } }`，不创建运行、不发信号。
  - start / restart 命中暂停且未带 `overrideHold`（`reason = 'hold'`）；
  - 任何动作命中 `lockedServices`（`'locked'`，`overrideHold` 无效）；
  - `agentForceStop = 'deny'` 时的 force-stop（`'force-stop'`）。

  被拒绝的 stop / force-stop 不参与停止优先（§4.2）。`ui` 请求永远不受规则约束。
- 关闭管理服务（`POST /daemon/shutdown`）发起的停止绕过托管规则：不产生暂停，不受锁定或 `agentForceStop` 拒绝；已有暂停与锁定保持不变，停止的 `operation` 动态按请求方照常记录。
- 范围：只约束服务的 start / stop / restart / force-stop；快捷操作、Maven、选项、配置路由不受影响。
- 动态：规则修改写 `policy`（`change = 'settings'` / `lock` / `unlock`），暂停产生与解除写 `hold` / `release`。带 `overrideHold` 且解除了暂停的操作，其 `operation` 条目标记 `overrideHold: true`。
- **安全说明**：客户端类型来自请求头；同一用户下的程序都能取得 socket 与 token。本机制防的是守规矩但会犯错的 agent，不是对抗恶意程序的安全边界。

## 17. 显式 Git 仓库与 Maven 工程（v1.4-A，v0.4.1）

本节覆盖 §11、§12 中“固定项目根目录”的限制；一个 DevPanel 项目仍可包含多个服务，无需按仓库拆分。

### 配置与校验

`ProjectConfig.repositories?: RepositoryConfig[]`，元素为 `{ id, name, path }`；`mavenProjects?: MavenProjectConfig[]`，在相同字段上增加可选 `executable: auto|wrapper|mvn`。数组顺序为显示顺序。每类最多 32 项；ID 匹配 `/^[a-z][a-z0-9-]{0,31}$/` 且类内唯一；名称非空白、1–80 字符、不含 NUL。拒绝元素未知字段。

`path` 为相对项目 root 的目录（可为 `.`），不允许绝对路径、`..` 段、NUL 或 `${` 占位符；真实路径必须位于项目 root 内，同类目录按真实路径去重。Git 目录必须直接有 `.git`（目录或 worktree 的文件）；Maven 目录必须有项目内的文件 `pom.xml`。保存及校验只检查文件系统，不执行 Git、Maven 或服务命令；无效配置返回 `CONFIG_INVALID`，issues 指向相应字段。

省略数组沿用旧行为：Git 使用 root 所在工作树，Maven 使用 root/pom.xml 和旧 `maven.executable`。显式 `[]` 表示无目标，不自动发现；程序不递归搜索额外仓库或 Maven 工程。配置 AI 根据实际目录与 POM 明确登记；人可在原生项目编辑器增删修改。聚合 POM 的 modules 仍由静态解析产生，不必逐个登记为工程。

### API 选择目标

- Git 所有读写路由（status、diff、stashes、stage、unstage、commit、stash、stash/apply）增加可选 query `repositoryId`。
- `GET /projects/:id/maven` 增加可选 query `mavenProjectId`；Maven 运行请求增加可选同名字符串字段。
- 显式列表只有一个目标时可省略选择；零个或多个目标时省略返回 400 `BAD_REQUEST`。未知 ID（包括旧配置携带 ID）也返回 `BAD_REQUEST`，不回退到其他目标。已登记 Git 目录不可用返回 422 `GIT_FAILED`，Maven 目录不可用返回 404 `MAVEN_UNAVAILABLE`。类型不合法的 Maven 请求 ID 返回 422 `MAVEN_INVALID`。
- Maven 历史 `GET /projects/:id/maven/runs` 可带 query `mavenProjectId`，验证 ID 后筛选；省略时返回项目全部 Maven 历史，兼容旧记录。
- CLI `maven modules|run <project-id> --maven-project <id>` 对应上述 selector；`--module` 是相对所选工程的模块 ID。

Git 文件路径、HEAD 检查、暂存、提交和储藏都限定在所选仓库；写操作仍仅允许 UI 发起。Maven 的模块路径、wrapper、模型缓存与执行 cwd 均相对所选工程根，环境变量和选项继承项目；显式工程使用自身 executable（默认 auto），忽略旧根目录 executable。任务请求保存解析后的目标 ID，详情保存实际 cwd。同一 DevPanel 项目最多一个 Maven 运行，保留原有并发限制和项目级历史保留数量。旧运行仍可通过历史和运行详情读取。

### 项目视图与原生界面

`ProjectView` 返回可选 `repositories`（配置列表）、`mavenProjects`（配置字段加 `currentRun/lastRun`，各按目标筛选）。保留 `maven` 项目级当前/最近结束运行摘要：显式数组非空时存在，为空时为 null；未提供数组时沿用 root/pom.xml 判断。

Git 页、Maven 页始终有入口；显式空列表显示未登记状态和编辑入口。非空列表显示目标选择器、名称和相对路径；首次显示选择首项。Git 缓存、文件选择、提交信息和差异窗口按项目与仓库隔离，已打开的差异窗口与确认对话框固定原目标。Maven 模型、模块、Profiles 和运行选项按工程隔离；切换后日志与运行历史显示所选工程，项目级并发限制保持有效。Git 文件支持状态颜色、文字标签、列表/目录树/顶层目录分组与状态筛选。
