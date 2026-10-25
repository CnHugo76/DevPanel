# DevPanel 后端设计与实测记录

日期：2026-10-21。当前实现覆盖 v0.3：服务控制、快捷操作/通用任务、Maven 静态视图、Git 本地工作流与 CLI；适用冻结契约 §11/§12。没有自动重启、业务健康检查、容器或外部进程接管。下面早期章节保留为 v0.1/v0.2 历史记录；v0.3 的实现、安全与验收见文末及 `docs/plan-v0.3.md`。

## 交付与模块

- `packages/daemon/src/manager.ts`：配置和运行的唯一事实来源；每服务串行队列、停止取消、运行恢复、资源聚合。
- `config.ts`：结构/目录/可执行文件校验、有效环境、敏感值保持与遮盖。校验不执行程序，也不执行登录 shell。
- `processes.ts`：macOS `ps` 快照、进程身份、后代发现、核验后逐 PID 发信号、CPU 差值计算。
- `logs.ts`：有界日志尾部、UTF-8 行拆分、跨块敏感值遮盖、分页、原子持久化及序号预留。
- `server.ts`：同一处理器服务 Unix socket 与回环 HTTP；认证、登录码、静态文件、SSE、单实例锁。
- `storage.ts`：私有目录、原子 JSON、ID、稳定错误及默认限额。
- `packages/cli/src/client.ts` / `main.ts`：Unix socket 客户端、所有契约命令、结构化输出与退出码。CLI 不创建业务进程。
- `packages/daemon/test/`、`packages/cli/test/`：真实进程/HTTP/CLI 集成测试和小型 Node fixtures。
- `packages/cli/src/setup-cli.ts` / `launch-agent.ts`：用户级命令 shim 与 macOS LaunchAgent 安装、卸载。
- 根 `package.json` 仅追加 `devpanel`、`devpaneld`、`setup:cli` 脚本。包依赖只加入所属包；pnpm 生成 lock 更新。

初版未修改冻结契约；本次按用户确认同步了三条前端提案，详见文末记录。未修改前端或 mock 实现。

## 关键工程决策

### 进程和操作

业务命令按 argv 直接 `spawn`，`detached: true` 创建独立会话/进程组，stdin 忽略，stdout/stderr 由 daemon 采集。只有显式配置 Shell 时才运行 Shell。

记录 PID、进程启动时间、PPID；根 PID 同时是独立进程组 ID。macOS 运行中每 250ms 通过复用的原生采样器读取一次 `sysctl(KERN_PROC_ALL)` 身份快照，发现组内进程与已核验父进程的后代；不为每次轮询启动 `ps`。原生采样器不可用时退回 `ps`，常规发现频率保持每 250ms 一次，启停边界仍即时核验。已发现的后代即使 detached 或被重新挂到 PID 1，仍按身份跟踪。僵尸进程不计入存活或资源。

信号逐个发送给本轮快照中 PID 和启动时间仍匹配的进程，不使用负 PGID 广播、进程名、端口或 killall。停止时继续发现新后代；同一停止操作只向每个身份发送一次 SIGTERM，避免干扰程序清理。强制停止重新核验并发送 SIGKILL，最多等待 5 秒；仍存活则保持 stopping/超时。

每个项目/服务 ID 一条 Promise 队列。停止到达即取消相关未完成 start/restart，取消标志在创建进程前、启动观察期、重启 stop→start 边界检查。项目内各服务按配置顺序发起，不等待前一个观察期结束。某服务失败不会回滚其他服务。

运行中修改配置只更新下一次启动的配置，当前运行保留 revision、argv、cwd、环境键、敏感值遮盖信息，以及私有的有效服务配置快照（服务配置、解析后的 cwd、默认停止超时、项目与服务 env 合并后的实际值）。`configChangedSinceStart` 按此快照比较，项目改名或其他服务变更不会误标；改回原配置后清除。快照随 state.json 持久化且不进入 API / SSE，文件权限 0600。停止采用本次运行快照的等待上限。删除运行中或仍有排队操作的服务会被拒绝。

### 日志与恢复

选择管道采集，避免将 stdout 直接写入一个无法可靠限制大小的应用持有文件。采集端持续读取，不等待浏览器、CLI 或磁盘；日志入有界内存尾部，异步每 500ms 将 dirty 尾部快照原子替换到磁盘。慢日志订阅在 `write()` 背压时暂停自身发送，不暂停采集；过期内容通过 truncated 告知。慢全局事件连接在积压超过 1MiB 后断开，重连取 snapshot。

默认保留每运行 32MiB、每服务 3 次、全局 1GiB，单行 64KiB、单页最多 2000 行。字节限额按序列化行计数（包含行元数据），保留额外头部空间。全局超限先删最旧的非当前运行，全部是当前运行时截断较旧尾部。快照写入时临时文件与旧文件短暂共存，**瞬时磁盘占用上界约为保留额度的两倍**，再加配置/身份文件；内存还有一次序列化快照及有界流缓冲，不能把保留额度当成整个 Node 进程的 RSS 上限。没有无限追加的业务日志文件。

stdout/stderr 按采集顺序合并；UTF-8 解码跨块保留，超长行切分并标记 partial。已标记敏感的环境值在换行/分段前遮盖，保留跨块重叠区；不会将这些值写入 sys 行、API 或 CLI。应用自行编码、变形或来源不明的秘密不属于自动识别范围。

日志序号每次预先在状态文件持久化预留 4096 个号码，再发送对应行。因此 daemon 崩溃丢失未刷盘尾部时不会复用已发送序号。恢复可能跳号，SSE 显示 gap；不伪造完整日志。日志 end 事件等待进程结束且 stdout/stderr 排空，再发送并关闭。

**管道故障边界：daemon 崩溃/被强制终止后，写入旧管道的业务程序可能收到 EPIPE/SIGPIPE 并自行退出。** 静默或正确处理 EPIPE 的进程可能继续存在。重启不可能接回旧管道：存活且可核验的旧运行显示 unknown + STATE_UNVERIFIABLE，禁止再次启动，可停止仍可核验的进程；确认已不在的运行以 daemon-lost 结束。API/CLI 能看见同一运行 ID、未知状态与日志缺口。没有承诺崩溃后服务一定存活或日志无损。

系统启动时间作为本地恢复元数据保存。确认系统已经重启时清除旧活动身份，保留配置与日志，状态 stopped；不会自动启动业务服务。

### 资源

仅有活动运行时执行系统进程快照。资源默认每 2 秒发布一次，CPU 使用累计 CPU 时间差/墙钟时间差，100% 表示一个逻辑 CPU；RSS 为已核验进程 RSS 之和；macOS 新增完整的 footprint 合计，界面优先显示它，RSS 保持独立语义并用于明确标注的回退。原生资源查询仅针对受管 PID，每 2 秒一次。项目按 PID+启动时间去重。所有客户端共享采样。

新进程未有两次样本时 CPU 为 null、status=sampling；扫描失败返回 unavailable；恢复的未知运行有可用但不完整数据时标记 partial。停止后移除旧资源结果，不把旧运行数据用在新运行上。

`refreshSelf` 每 2 秒通过 helper 的 `O` 请求读取 daemon 和 helper 的 CPU/RSS/footprint，缓存 self 与 toolResources；无项目时仍采自身资源，但不做全机进程发现。单次失败时 self 回退 Node CPU/RSS，helpers/total 标为 partial 并保留原样本时间；连续 3 次失败后才明确不可用。失败重试采用 2/4/8/16/30 秒退避，有效响应后重置。业务子进程不计入 self 或工具合计。

### 生命周期、环境、持久化和安全

`devpanel daemon start` 通过独立会话、文件输出和 unref 启动 daemon，终端/CLI 退出不影响它。Unix socket 为 `<home>/run/devpanel.sock`；HTTP 默认 47823，可用 DEVPANEL_PORT=0 请求空闲端口。发现文件只读自本次 DEVPANEL_HOME。

单实例由私有目录排他创建与 owner 的 PID+启动时间+系统启动时间核验保证；恢复旧锁时用额外排他恢复锁串行化。缺损或无法核验的锁拒绝启动，避免猜测归属。极端情况下启动恰好在锁创建而 owner 写入前崩溃，需人工核验后清理锁；不会自动删除不明锁。

首次启动捕获 daemon 进程的 HOME/USER/LOGNAME/SHELL/TMPDIR/LANG/PATH 到 environment.json，后续复用。有效环境=基础环境←项目 env←服务 env。不会随 CLI 当前 shell 悄悄变化。工具路径可显式在配置中保存。LaunchAgent 的环境来源与安装方法见下节；不运行登录 shell 来抓环境。

JSON 写临时文件后 rename；目录 0700、文件和 socket 0600，进程 umask 077。敏感值只保存在当前用户私有数据文件中，未引入钥匙串或数据库。运行元数据和序号预留写盘失败时不继续发布未经预留的日志序号。

HTTP 仅监听 127.0.0.1，校验 Host/Origin，不提供 CORS 放行。API 使用 Bearer 或 HttpOnly、SameSite=Strict Cookie；所有非 GET 请求均需 X-DevPanel-Client。登录 code 仅 Unix socket 可申请，60 秒有效且一次使用。静态页面本身无需认证，不包含项目数据；静态路径也核验 realpath，拒绝越界符号链接。

彻底退出先停止所有服务，任何失败都保留 daemon。停止期间拒绝新的 start/restart，避免关闭过程中又产生业务进程。外部 SIGTERM/SIGINT 只结束管理服务并保存记录，按上述故障恢复语义处理业务进程；正常退出应使用 `devpanel daemon stop --stop-services`。

## 安装与开发运行

需要 Node >=24、pnpm 12。在仓库根目录执行，安装前与前端协调，避免同时修改 lock：

```sh
pnpm install
pnpm typecheck
pnpm --filter @devpanel/daemon --filter @devpanel/cli test
pnpm build
```

### 供其他仓库和 Agent 使用的命令安装

在本仓库执行一次：

```sh
pnpm setup:cli
# 可选自定义目录（不需要 sudo）：
pnpm setup:cli --bin-dir "$HOME/.local/bin"
```

默认生成 `~/.local/bin/devpanel` 和 `~/.local/bin/devpaneld`，权限 0755。shim 用 `/bin/sh` 的 `exec` 调用安装时选定的 Node 稳定绝对路径与本仓库入口，完整透传参数，不依赖调用方工作目录、pnpm 或 PATH 中的 Node。不会启动 daemon 或任何项目。已有 DevPanel shim 可以重复更新；遇到其他文件或符号链接会拒绝覆盖，且先检查两个目标再写入。

如果该目录尚未在 PATH 中，在调用方终端或 Agent 的启动环境里设置：

```sh
export PATH="$HOME/.local/bin:$PATH"
devpanel --help
```

安装器只输出这条设置建议，不修改 shell 配置、`/etc/paths`、`/usr/local/bin` 或其他系统级配置。已打开的 Agent 不会自动获得新的 PATH；应在它的启动环境中设置，或直接调用 `~/.local/bin/devpanel`。跨仓库机器读取 JSON 可直接执行 `devpanel status --json`，没有 pnpm 脚本横幅。依赖已安装的本仓库与 Node 必须保留；Homebrew 同一 formula 升级无需重装 shim；移动仓库、切换 formula（如 node@24 → node@26），或删除非 Homebrew 的固定 Node 路径后，重新执行 `pnpm setup:cli`。删除这两个 shim 即可移除命令入口，不影响数据。

### macOS 登录自启（只启动 daemon）

用户需要日常自启时，执行：

```sh
devpanel daemon install --json
devpanel daemon status --json
# 卸载自启，已有活动服务时会拒绝：
devpanel daemon uninstall --json
# 明确要求同时正常停止业务服务后卸载：
devpanel daemon uninstall --stop-services --json
```

这是用户 **登录 GUI 会话时自启** 的 LaunchAgent，不是登录前的系统服务。安装写入 `~/Library/LaunchAgents/io.devpanel.daemon.<数据目录哈希>.plist`（0600），通过 `/bin/launchctl bootstrap gui/<uid> <plist>` 立即加载。不同 DEVPANEL_HOME 使用不同 label；同一目录的符号链接别名归一化。只支持 macOS，无需 sudo、不修改系统 LaunchDaemons。安装前若同一数据目录已有手动启动的 daemon，会提示先正常停止，避免把已有进程误当成 launchd 管理的进程。

plist 的 ProgramArguments 只有 Node 的绝对路径和 daemon 入口，不包含项目命令；`RunAtLoad=true`、`KeepAlive=false`。关闭 daemon 后不会被持续拉起，下次登录会重新启动；重启 daemon 也不会自动启动已登记项目。`AbandonProcessGroup=true`，业务进程仍只由 daemon 的核验/停止逻辑处理。已有加载的安装重复执行不会重启 daemon；路径或基础环境要更换时先卸载再安装。未加载的旧安装重新 bootstrap 时保留已有 plist 环境。launchd 的 stdout/stderr 指向 `/dev/null`，不生成无界启动日志；启动未就绪会返回错误并保留安装信息，可卸载后用 `daemon start` 的 `daemon-start.log` 排查。

Node 可执行路径在**安装时**确定，shim 与 plist 共用同一个解析函数：遇到 `<prefix>/Cellar/node[@主版本]/<版本>/bin/node`，改为 `<prefix>/opt/node[@主版本]/bin/node`，核验该路径存在且可执行，并保留符号链接路径、不做 realpath 展开。例如 Apple Silicon 使用 `/opt/homebrew/opt/node@24/bin/node`，Intel 使用 `/usr/local/opt/node@24/bin/node`；未版本化的 `node` formula 使用 `opt/node/bin/node`。opt 链接缺失或不可执行时拒绝生成安装文件，提示修复 Homebrew 链接。非 Homebrew 安装保留当前 Node 的绝对路径（包括显式传入的稳定别名）；版本管理器若移除该路径，需要重新安装入口。

launchd 直接执行 plist 中这个绝对路径，**不依赖 launchd 的 PATH，也不执行 `command -v` 或登录 shell**。基础 PATH 仍只决定业务命令的查找环境，来源如下。旧版已生成的 Cellar shim 需重新执行 `pnpm setup:cli`；旧版 plist 需先 `daemon uninstall` 再 `daemon install`，已加载的安装不会被隐式替换。若已有服务运行，卸载需要明确加 `--stop-services`。

基础环境有明确来源：

1. 数据目录已有 `environment.json` 时，安装使用其中的 HOME/USER/LOGNAME/SHELL/TMPDIR/LANG/PATH 白名单，保留之前保存的 PATH，不用当前终端覆盖。
2. 首次安装没有该文件时，捕获**执行 install 的进程环境**中同一白名单到 plist；PATH 缺省为 `/usr/bin:/bin:/usr/sbin:/sbin`。daemon 首次启动再将基础环境保存为 `environment.json`，后续启动复用。不会从登录 shell、zshrc 或 launchd 的默认稀疏 PATH 猜测工具目录。
3. plist 另显式保存 DEVPANEL_HOME、DEVPANEL_PORT（默认 47823，可设 0）及可选 DEVPANEL_UI_DIR；不复制其他变量，如 TOKEN、NODE_OPTIONS。项目实际环境仍为基础环境 ← 项目 env ← 服务 env。所需 JAVA_HOME 等应显式写入项目/服务配置；PATH 的项目级覆盖同样有效。

卸载先核对 launchd job 的 PID 与 socket 返回的 daemon PID，然后调用现有 shutdown 接口。有活动服务而未给 `--stop-services` 时返回 PROJECT_RUNNING；正常停止超时则原样返回 Operation 和退出码 7，保留 job/plist。确认 daemon 不再响应后才 bootout 并删除该 plist；无法核验、关闭未完成或 bootout 失败也保留安装。重复卸载无副作用，不删除数据、配置、日志或 CLI shim。

这两个命令属于用户要求的本地安装入口；没有新增 HTTP 路由或修改共享类型，冻结的接口契约文件保持原样。

以下命令始终使用新建的临时 HOME，不接入真实项目：

```sh
cd /path/to/DevPanel
export DEVPANEL_HOME="$(mktemp -d /tmp/devpanel-demo.XXXXXX)"
export DEVPANEL_PORT=0
# 可选；默认已经是仓库 apps/ui/dist
export DEVPANEL_UI_DIR="$PWD/apps/ui/dist"
# 直接运行 CLI，保证 --json stdout 不夹带包管理器脚本横幅
function devpanel() { node /path/to/DevPanel/packages/cli/src/main.ts "$@"; }
devpanel daemon start --json
devpanel daemon status --json
devpanel open
```

`pnpm devpanel daemon start` / `pnpm devpanel open` 也可用；机器读取 JSON 时推荐直接调用 CLI。

可运行的模拟项目演示（仅显式 start 才运行）：

```sh
mkdir -p "$DEVPANEL_HOME/demo-project"
node --input-type=module <<'JS'
import {writeFileSync} from 'node:fs';
import {join,resolve} from 'node:path';
const home=process.env.DEVPANEL_HOME;
writeFileSync(join(home,'demo.json'),JSON.stringify({
  schemaVersion:1,name:'临时验收项目',root:join(home,'demo-project'),
  services:[{id:'backend',name:'后端',cwd:'.',
    command:[process.execPath,resolve('packages/daemon/test/fixtures/service.mjs'),'normal'],
    stopTimeoutSec:1}]
}));
JS
project_id="$(devpanel project register --config "$DEVPANEL_HOME/demo.json" --json | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).project.id')"
devpanel status "$project_id" --json
devpanel start "$project_id" --json
devpanel logs "$project_id" --tail 20
devpanel stats "$project_id" --json
devpanel restart "$project_id" --service backend --json
devpanel stop "$project_id" --json
devpanel project remove "$project_id" --json
devpanel daemon stop --json
```

`--no-wait` 返回已接受的 Operation，退出 0 仅表示请求已接受。默认等待终态，默认总等待 60 秒；等待超时退出 8。取消退出 9、部分成功 6、停止超时 7；daemon 不可达退出 3，不自行启动服务。`operation <id>` 可继续查询。

## 前端联调交接

1. 构建 UI 后，由真实 daemon 托管 `apps/ui/dist`，使用 `devpanel open` 完成 Cookie 登录。
2. 若使用 Vite 代理，需正确处理真实 daemon 的 Host/Origin 和认证。不要用 mock 的免认证行为推断真实服务，后端不会放宽回环认证。
3. 状态 SSE 首条为 snapshot；日志是独立的 lines/truncated/gap/end/ping 流。关闭日志订阅不会影响服务或后台采集。
4. 控制 HTTP 202 只是接受操作。展示操作结果需等待 `/operations/:id/wait` 或 operation 事件。
5. 对于 unknown，只允许对可核验进程停止；重新 start 会拒绝。停止超时维持 stopping 与 stopTimedOut=true。

## 验收记录

环境：macOS 27.0.1 arm64，Node v24.21.0，pnpm 12.4.1。所有测试使用 mkdtemp 目录与上述 fixtures，结束后按身份停止测试进程。未触碰真实 DevPanel 数据或注册真实业务仓库。

测试主入口：`pnpm --filter @devpanel/daemon --filter @devpanel/cli test`。HTTP 测试使用与 UI 完全相同的真实路由，但下表区分后端验证和实际浏览器体验，未把 HTTP 测试称为 UI 实测。

| 产品 §16 场景 | 后端实测与关键断言 | 完整 UI 验收 |
| --- | --- | --- |
| AI 注册项目 | CLI 注册成功；HTTP/SSE 同一项目；runs=0、state=idle | 项目出现的视觉检查待前端联调 |
| 重复注册 | 相同返回 created=false；不同 409 CONFIG_CONFLICT；revision 冲突 409 | 后端通过 |
| UI 启动、CLI 查询 | HTTP start 与 CLI status 返回同一 runId | 实际按钮待联调 |
| CLI 启动、UI 查看 | HTTP 可读同一日志与 RSS/CPU，HTTP stop 可结束它 | 实际显示待联调 |
| UI/CLI 同时启动 | Promise.all 同时调用，history.length=1，runId 一致 | 后端通过 |
| 一个项目两个服务 | 单独 stop backend，frontend 保持 running；合计进程数等于去重后服务和 | 后端通过 |
| 命令/目录错误 | 缺失命令注册 422；运行前目录消失产生失败运行 CWD_UNAVAILABLE | 后端通过 |
| 程序自行退出 | code 0/1 早退均操作失败；运行记录分别 exited/failed，日志仍可读 | 后端通过 |
| 启动器与子进程 | fixture 含 detached 孙进程，backend processCount>=3；停止后所有已记录身份消失 | 后端通过 |
| 正常停止超时 | ignore SIGTERM：CLI 退出 7；state=stopping、stopTimedOut=true；force-stop 成功 | 强制停止入口待联调 |
| 重启中停止 | restart 操作 cancelled、cancelledBy 指向停止；等待后不再启动 | 后端通过 |
| 关闭窗口/AI 会话 | CLI 进程退出后 daemon 与业务 PID 身份仍在；重新查询同一 runId | 实际关窗重开待联调 |
| 服务重启 | 新 runId，旧日志仍可读；最近历史最多 3 条 | 后端通过 |
| 日志持续增长 | 高速输出下截断；测试保留 64KiB 上限，磁盘快照低于 66KiB；stderr/ANSI/UTF-8 超长行保留 | 滚动与复制待联调 |
| 资源缺失 | 首样本 sampling、cpu=null；无样本 unavailable；PID 启动时间不符不发信号 | 真实权限故障的 UI 显示未测 |
| 管理连接中断 | daemon SIGKILL 后 CLI 退出 3；恢复旧运行 unknown，重复 start 拒绝 | 断连横幅与重连待联调 |
| 非受管同名进程 | 同一 Node fixture 额外进程不计入、不停止，身份仍匹配 | 后端通过 |
| 移除项目 | 活动项目 409；停止后移除，根目录 keep.txt 原样存在 | 后端通过 |
| 本地接口 | 无认证 401、错误 Host/Origin 403、缺客户端头 400；code 二次使用 401；socket 0600 | 后端通过 |

补充：跨块/跨换行敏感值完全遮盖；崩溃后序号不复用；单实例第二次启动拒绝；CLI 等待超时退出 8；关闭失败不退出 daemon，关闭过程中禁止新的启动请求。

空闲 self 实测（无业务运行、无窗口）：多次独立 daemon 样本约 **0.06–0.11% 单核 CPU，85.8–91.6 MiB RSS**。命令等价于启动后等待至少 4 秒再执行 `devpanel daemon status --json`，测试输出保存关键测量行。这是本机源码入口 Node 24 的短时样本，不是长期压力测试或桌面壳的总占用。

全仓检查状态与最后一次测试数量见文档末尾更新。

## 限制与待联调

- 三条已确认的前端提案已在 `contract/CHANGES.md` 移入“已生效”，第一条采用方案 1。
- 管道故障可能影响业务进程；恢复明确 unknown/gap，不承诺无损。最近约 500ms 未刷盘日志可能丢失。
- `ps lstart` 在本机的进程创建时间精度为秒；核验与 kill 之间仍有操作系统级竞态。没有宣称具备 pidfd 级原子身份信号能力。
- 轮询发现存在窗口：在两次扫描之间立即 double-fork 并完全离开组/父链、且从未被发现的进程不受托管保证。已发现的 detached 后代持续跟踪。
- 快照持久化有临时双份磁盘与序列化内存开销；限额限制保留数据，不能保证任意极端输出速度下应用从不遇到内核管道调度延迟。
- 提供用户级 shim 和 LaunchAgent 安装命令；测试仅在临时目录写 plist 并临时加载隔离的 job，未安装到真实用户 LaunchAgents，也未自动修改全局 PATH。`devpanel open` 的一次性登录协议已测；系统浏览器实际拉起未自动验收。
- 实际系统重启、真实权限受限进程和完整浏览器交互未测。完整“真实业务项目→打开界面→用户停止”验收应由用户授权真实项目后，与前端共同完成。

## 已接受契约提案落地（2026-10-20）

- `/config/validate` 无项目上下文，接受项目与服务 env 中的 `{secret:true}`。注册 / 更新额外检查同作用域已有敏感值，缺失时返回 422 与 `details.issues`；校验不保存、不执行命令。占位符 PATH 无法解析裸程序名时不误报 COMMAND_NOT_FOUND，保存时仍按实际 PATH 校验。
- `ServiceView.error` 对 spawn 失败、启动期退出、无法核验保留对应错误；启动成功后自行退出为 null，使用 `lastRun.exit`。确认停止后清除旧 STOP_TIMEOUT。
- 有效配置按每服务启动快照比较：覆盖服务 argv 变更、项目 env 覆盖关系、敏感值轮换、改回原配置、单服务重启及从磁盘重载。旧版本缺少快照的记录，仅在 revision 仍相同的情况下可以重建；若 revision 已变化，无法还原历史有效配置，保守标记为已修改，直到该服务重新启动。
- STOP_TIMEOUT 携带 `details: { timeoutSec, remaining }`；remaining 在截止点重新核验，统计仍存活进程。重启因停止超时而失败时也保留 details。进程树测试覆盖最初 3 个进程、超时仅余 1 个的情况。
- 契约类型结构不变，api.md 与 index.ts 注释同步，待决提案已清空。

## 最后一次检查汇总

- `pnpm typecheck`：全仓通过（contract、daemon、CLI、UI、mock）。
- `pnpm test`：全仓 **92/92** 通过（UI 52、mock 7、daemon 18、CLI 15），包含恢复、安装、Homebrew 升级及测试超时退出回归。
- `pnpm --filter @devpanel/daemon --filter @devpanel/cli build`：两个后端包通过。
- 本次没有运行前端构建或浏览器验收。
- 测试入口均显式设置 DEVPANEL_HOME 到 mktemp 目录，服务 fixture 使用独立临时根目录；没有注册真实项目、读写真实 DevPanel 数据或创建 Git 提交。

## 本次联调修复与安装验证（2026-10-20）

- 根因：运行结束的公共 `finish` 只为 self-exit/user-stop/force-stop 清空 error，漏掉 daemon-lost。现在除需要保留启动错误的 spawn-failed 外，结束运行都清空瞬时错误；启动期异常仍由启动逻辑设置 EXITED_DURING_START。恢复为 unknown 时清掉 stopTimedOut，并设置 STATE_UNVERIFIABLE。
- 对旧版本已落盘的 terminal daemon-lost 记录也清理残留 error/stopTimedOut，避免升级后旧状态继续显示“尚未停止”。
- 回归先红后绿：真实 CLI 启动忽略 SIGTERM 且持续写日志的 fixture → stop timeout → 按 PID+启动时间核验后 SIGKILL daemon → fixture 因旧管道断开退出 → CLI 重启 daemon。断言 failed、currentRun=null、lastRun.exit.reason=daemon-lost、stopTimedOut=false、error=null，且磁盘记录同步清空。
- 附加恢复测试覆盖进程仍存活时的 unknown、模拟系统 boot 时间变化时的 stopped，以及旧版本 terminal 记录迁移；模拟 boot 不是实际重启机器。
- 安装测试覆盖跨目录/最小 PATH/引号路径、参数透传、可重复安装、拒绝覆盖已有命令，及 plist 的 XML 校验、白名单环境、PATH 来源、bootstrap 失败回滚、拒绝卸载仍运行/停止超时/归属不符的 daemon。
- 真实 launchd 验证使用临时用户目录、临时 DEVPANEL_HOME、随机端口和独立 label：bootstrap → 注册 fixture（不执行）→ uninstall → 再安装后仍为 idle、lastRun=null → 再次卸载，确认 socket 不可达且 job 消失。未触碰真实用户的 LaunchAgents 或 DevPanel 数据，未注册真实项目。

## Node 升级与测试超时补充（2026-10-20）

- shim 与 LaunchAgent 不再固化 Homebrew Cellar 的版本号；测试模拟 opt 切换和旧 keg 删除，验证原 shim 与 plist 的 Node 入口仍可执行，并覆盖 Apple Silicon/Intel 前缀、node/node@24、缺失和不可执行的 opt 路径。
- daemon 与 CLI 的 `test` 脚本都加入 `--test-timeout=120000 --test-force-exit`。这是 Node 测试运行器的测试超时上限，不是全仓总时限；daemon 仍保留 `--test-concurrency=1`。临时挂起测试实测发现：仅设 timeout 会报告超时，但未关闭的定时器仍可能阻止进程退出；配合 force-exit 后，在测试（含清理钩子）完成或超时后退出，报告测试名称、超时原因和非零退出码。回归测试读取两个包的实际 runner 参数、仅缩短测试用超时值，验证这一行为。force-exit 不是业务进程清理机制，原有按身份核验的清理钩子继续保留。
- 偶发 secret fixture 挂起尚未复现或定位，本次增加超时防护，不将其称为已修复的业务逻辑缺陷。

## v0.2 B1–B3 后端实现（2026-10-20）

### 选项与运行快照

`params.ts` 集中处理类型 / choices / min-max 校验、引用定位、一次性替换、shell 字面量转义、设置者元数据和删除写回。`config.ts` 将这些规则接入原有校验、敏感值解析和响应遮盖。保存的 command/env 保留模板；校验只做静态展开以核验程序和 PATH，保存不启动、不重启。启动时用该次配置生成实际 argv/env，插入的值不会递归作为模板求值；数字使用十进制（包括很大 / 很小的数），布尔使用 true/false。项目 env 与服务 env 先按覆盖关系合并，再展开非敏感值；敏感 env 内的占位符原样保留。

shell 识别使用展开后的程序文件名及 -c / -lc 等选项，只转义脚本参数中的插入值，不改 argv 分组。支持未引用、单引号和双引号内的占位符，值中的单引号使用 POSIX 的关闭引号、转义单引号、重新打开引号形式。建议配置作者把占位符写在普通参数位置，避免将其用于 shell 语法、here-document 或复杂嵌套求值结构。

`manager.ts` 在私有启动快照保存实际命令和有效环境，供 `configChangedSinceStart` 比较；公共运行记录保存该次本服务实际引用的选项值（排除被服务覆盖的项目 env 引用；secret 仅 `{secret:true}`）与遮盖 secret 片段的实际命令（`••••`）。secret 选项也进入已有跨块日志遮盖器和响应 / 事件遮盖流程。旧版运行记录缺少 params 时补 `{}`，不倒填当前值冒充历史值。磁盘存储仍沿用私有目录、0600 文件与原子替换。

整份更新在校验前保留 setBy=user 的旧值，响应列出 keptUserValues；显式 overrideUserValues=true 才覆盖。值未变时保留 setBy/valueUpdatedAt，说明字段变更只更新 describedBy；请求自带的响应元数据不能伪造设置者。注册幂等比较排除这些元数据，已有根目录按保护后的配置比较，仍不会静默更新。被保护的旧值若为 secret，其敏感标记也保留。

细粒度 POST/PATCH/DELETE 复用 revision 校验、持久化和 project.upsert，但只校验选项定义与引用，不因 root/cwd/program 暂时不可用而阻止编辑；PATCH 是明确改值操作，不套用整份更新保护。DELETE 默认 inline=false；引用存在时返回 PARAM_IN_USE。普通值写回时重新转义 `${`，避免下次启动把值内的文本误当新占位符。secret 被任何命令引用时拒绝写回；仅 env 引用时将该环境变量完整展开并转为敏感变量。由于契约规定敏感 env 不再做替换，这种转换会同时固定该环境变量中其他选项的当前值；其他环境变量和命令中的引用仍保留。

### 真实监听端口与成本

`listening.ts` 在共享资源采样中批量调用 macOS `/usr/sbin/lsof -nP -a -p <已核验PID列表> -iTCP -sTCP:LISTEN -F pftnT`。`-a` 将 PID 与 TCP LISTEN 条件取交集，`-nP` 禁止主机名和服务名解析；不会扫描端口或查询非受管 PID 的套接字。Linux 使用 PATH 中的 lsof，当前验收平台为 macOS。

每个资源周期最多一次 lsof，覆盖所有服务的已核验根进程及已发现后代；默认周期 2000ms，与客户端数量无关。无活动运行或没有已核验 PID 时不调用。lsof 限时 1500ms、输出上限 4MiB；结束后再用 ps 核对 PID+启动时间，身份不符的数据不发布。端口从不参与进程归属或停止判定。由于套接字读取增加了共享采样的异步窗口，启动观察期若已收到退出事件，会重新核验存活后代后再决定 started/EXITED_DURING_START，避免沿用退出前的共享快照。

同一服务按 address+port 去重，保留一个实际持有者 PID；IPv4/IPv6 分别解析，127/8 和 ::1 为 loopback，通配监听为 all，其余为 other。lsof 成功或无匹配且无诊断（退出码 1）可确认 `[]`；读取失败、超时、身份变化或尚未采样返回 `null`，不复用旧端口冒充本周期结果。停止后 GET stats 和后续 stats 事件移除该服务。

本机三个受管 fixture 的五次连续采样（含 lsof 和追加 ps 身份复核）在较轻负载下为 **49.3 / 51.4 / 53.3 / 56.8 / 56.9ms**；并行构建 / 测试期间另一组为 **332.2 / 561.4 / 341.8 / 243.7 / 253.7ms**。这些是墙钟耗时，不是 daemon CPU 用量；因此采用每周期批量一次，而不是按服务调用。与原有 250ms 身份发现轮询相比，每个 2 秒采样周期新增一次 lsof 和一次 ps。lsof 缺失 / 权限受限时只影响端口可用性。

身份核验沿用 ps lstart 的秒级精度，读取前后核验不能消除操作系统层面的全部竞态；不宣称 pidfd 级原子保证。未实际验证 Linux 或真实权限受限进程。原生程序视觉和通知行为由前端联调验收。

### 新 CLI 用法（隔离的可运行示例）

```sh
cd /path/to/DevPanel
export DEVPANEL_HOME="$(mktemp -d /tmp/devpanel-params-demo.XXXXXX)"
export DEVPANEL_PORT=0
function devpanel() { node /path/to/DevPanel/packages/cli/src/main.ts "$@"; }
mkdir -p "$DEVPANEL_HOME/project"
node --input-type=module <<'JS'
import { writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
const home = process.env.DEVPANEL_HOME;
writeFileSync(join(home, 'config.json'), JSON.stringify({
  schemaVersion: 1, name: '选项演示', root: join(home, 'project'),
  params: [{ key: 'port', label: '端口', type: 'number', value: 0,
    min: 0, max: 65535, description: '0 表示由系统分配空闲端口' }],
  services: [{ id: 'server', name: '服务', cwd: '.',
    command: [process.execPath, resolve('packages/daemon/test/fixtures/listening.mjs'),
      '127.0.0.1', '${port}'], stopTimeoutSec: 1 }]
}));
JS
devpanel daemon start --json
project_id="$(devpanel project register --config "$DEVPANEL_HOME/config.json" --json | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).project.id')"
devpanel param list "$project_id" --json
devpanel param set "$project_id" port 0 --json
devpanel project rules "$project_id"
devpanel start "$project_id" --json
devpanel stats "$project_id" --json
devpanel param set "$project_id" port 8081 --json  # 当前运行不变
devpanel param remove "$project_id" port --inline --json
devpanel stop "$project_id" --json
devpanel project remove "$project_id" --json
devpanel daemon stop --json
```

`param set/remove` 可带 `--if-revision N`；省略时先读取最新 revision 再提交，仍保留乐观并发检查。number/boolean/enum 值无效退出 2，不回显输入。整份更新的显式覆盖入口：`devpanel project update <项目ID> --config <文件> --if-revision <版本> --override-user-values --json`。未提供该开关时保护人设置过的值。secret 的 `param list/set` 输出均来自已遮盖响应；通过命令行传入 secret 仍会进入调用方 shell 历史 / OS argv，CLI 不额外提供秘密输入通道。

### B1–B3 验证记录

所有服务测试均使用临时 DEVPANEL_HOME 与临时项目根目录；保留原有 `--test-timeout=120000 --test-force-exit`（daemon 仍串行）。新增 10 项后端测试，daemon 合计 28 项，CLI 原有 15 项；CLI 选项操作在 daemon 的真实 HTTP/Unix socket 集成测试中验证。

| 要求 | 实测结果 |
| --- | --- |
| argv 元素内替换、`$${` 字面量、数字/布尔格式化、项目与服务 env | 通过；读取实际子进程输出核对 argv/env；指数形式数字转十进制，敏感 env 不展开 |
| PARAM_UNKNOWN / PARAM_INVALID / WARN_PARAM_UNUSED | 通过；覆盖未知 key、类型、choices、上下界、畸形定义、未引用选项及缺值 secret 的独立校验/保存差异 |
| shell 值含空格、单引号、`$`、`;` | 通过；真实 `/bin/zsh -lc`，未引用/单引号/双引号位置均输出原始字面值；删除写回后再启动仍一致 |
| UI 改值后 CLI 整份更新保护与显式覆盖 | 通过；真实 CLI 更新返回 keptUserValues；`--override-user-values` 恢复配置文件值；响应元数据无法伪造 setter |
| configChangedSinceStart 按引用方比较 | 通过；改引用方标记、未引用方不标记、恢复原值清除；运行 ID 不变，原快照不变 |
| 删除未引用/拒绝未 inline/写回/secret 限制 | 通过；未引用直接删、引用返回 409、普通值写回后启动、secret 命令引用拒绝、secret env 转敏感后启动 |
| 端口仅来自受管进程 | 通过；真实监听 127.0.0.1 与 0.0.0.0；同端口的非受管 ::1 监听未出现且停止操作不影响它；停止后 services 清空 |
| 端口缺失语义与身份变化 | 通过；无监听返回 []；未读到/身份失配返回 null；解析单测覆盖 IPv4/IPv6、scope、去重及非 LISTEN 排除 |
| secret 不回显 | 通过；配置、运行 argv/params、日志与 CLI 均无原值；服务运行中更新不执行新命令 |

第一次完整通过：全仓 `pnpm typecheck` **6.15s**；全仓 `pnpm test` **102/102，57.31s**（UI 52、mock 7、daemon 28、CLI 15）。后端 `build` **2.78s** 通过。首轮全仓检查曾受前端并行修改中的类型缺失影响，后续已通过；早退回归曾暴露共享采样快照竞态，修复后上述完整测试通过。

文档中的完整 CLI 示例已原样执行，**4.28s**，注册、list/set/rules、启动、真实端口查询、运行中改值、inline 删除、停止、移除、关闭 daemon 均成功。临时项目和测试 daemon 已正常停止，未触碰真实已注册项目。

本次未修改接口契约，无新增契约提案；原生 macOS 程序联调仍由前端阶段完成。

最终复核：`pnpm typecheck` **1.40s** 通过；前端并行补充 mock 测试后，全仓 `pnpm test` **120/120，52.92s**（UI 52、mock 25、daemon 28、CLI 15）。后端源码没有为此改动。

### 已接受的 7 条选项澄清落地（2026-10-20）

用户已确认接受并指派后端同步契约，`contract/api.md` §3.1 与共享类型注释已写入全部七条，`contract/CHANGES.md` 已移到“已生效”。未增加字段或路由，未修改前端实现。

| 条款 | 原实现差异与当前行为 | 验证 |
| --- | --- | --- |
| 1 路由 | 原来复用整份更新，会被 cwd/program 错误阻止；现在仅执行选项校验并保存，不重新 realpath 已存 root。缺少 DELETE ifRevision 从版本冲突改为 400 BAD_REQUEST。未知 key 的 404 PARAM_UNKNOWN、无效值的 422 CONFIG_INVALID / PARAM_INVALID 原已符合 | 真实 HTTP 验证 POST/PATCH/DELETE 错误码；删除整个临时项目目录与程序后仍能新增、改值、inline 删除；校验失败不保存，成功递增 revision 并发 project.upsert，无运行记录 |
| 2 保护不兼容 | PUT 原已返回 422，现在加 overrideUserValues 提示；POST 原也报 422，现在仅对不兼容的受保护选项用请求值比较，返回 409 CONFIG_CONFLICT，不更新存储 | 覆盖 type、choices、min、max；失败不改 revision 或原值；显式 override 成功 |
| 3 shell 范围 | 原已只转义脚本 argv，保持此行为 | 真实 zsh -lc 检查脚本内占位符及后面的 $0/$1 值含空格、单引号、美元符与分号时原样输出；inline 后再启动一致 |
| 4 快照范围 | 原记录项目全部选项，现在只记录命令和合并后的非敏感 env 实际引用项 | 双服务测试排除未使用项、被覆盖的项目 env 引用、敏感 env 中不参与替换的文本；secret 引用只记标记 |
| 5 识别 | 原对任意非空闭合名称检查未知 key；现在统一 token 只匹配合法 key。替换、校验、usedBy、删除和运行快照共用该识别 | `${a:-b}`、`${}`、未闭合、非法首字符/连字符/过长 key 原样保留；`${HOME}` 报 PARAM_UNKNOWN，`$${HOME}` 输出字面量 |
| 6 inline | 原已重新转义 `${` 并对 secret env 完整展开，保持此行为 | shell 写回重启一致；secret env 中另一选项的当前值也写回、变量转敏感，其他选项定义保留 |
| 7 警告 | 原对 secret 引用仍提示；现在值完全由 secret 占位符组成时不提示 | 单个/多个 secret 引用免警告；带前缀、混合普通选项、转义占位符和 shell 默认值文本仍警告 |

原提案列出的差异已全部对齐。旧运行记录保留当时已保存的快照，不使用当前配置反推和改写历史 params；新运行使用收窄后的引用范围。

验证结果：全仓 `pnpm typecheck` 通过（2.50s）；全仓 `pnpm test` **125/125** 通过（43.20s；daemon 33、CLI 15、UI 52、mock 25）；后端两包 `build` 通过（1.05s）。新增 5 项澄清测试覆盖上表；补充了“保护比较同时遇到畸形选项”返回 422 而非 500 的回归并通过。所有运行使用临时 DEVPANEL_HOME；保留 test-timeout/test-force-exit 参数。`git diff --check` 通过。

### 联调修复：短敏感值与 socket 路径（2026-10-20）

**短敏感值遮盖。** 根因是 `mask`、`Manager.safe` 和校验结果共用的递归遮盖，对每个字符串都做无长度限制的子串替换；例如测试 secret 为单字符时会误伤项目名 fixture 和 pathUsed。现在通用响应 / 事件的兜底遮盖采用 **8 个 Unicode 字符**的子串匹配门槛：长度不足 8 的秘密，只在整个字符串等于秘密时遮盖；达到 8 字符仍遮盖其任意子串。阈值是字符数，不是 UTF-8 字节数。忽略空秘密、优先匹配最长值、单轮替换，避免重叠秘密部分漏出或后续匹配再改写 `[REDACTED]` 标记。

secret env 对象仍无条件移除 value，secret 参数仍无条件省略 value，运行 command 中来自 secret 参数的片段仍无条件显示 `••••`，这些基于来源的遮盖不受长度门槛影响。stdout/stderr 收集器及 daemon 的 sys 日志显式使用严格模式（最小长度 1），保留跨块、跨换行的遮盖。日志可能因短秘密而遮盖普通文字，这是为了保持日志中的秘密不泄露；普通响应的项目名、路径等不会再因短子串碰撞被破坏。

取舍：这是用户允许的“最小长度 + 整值匹配”方案，不是完整的敏感数据流追踪。若短秘密被人为复制进普通非敏感文本字段的一部分，通用响应兜底不再识别这段子串；若字段整体恰好等于秘密，仍会遮盖。较长秘密碰巧与元数据相同的子串也仍会被遮盖。这个规则避免凭一个常见短字符破坏整个响应；真正的 secret 字段及 secret 参数展开继续由来源明确的遮盖保证。此段取代旧说明中“所有响应字符串无条件按秘密子串替换”的行为描述。

**Unix socket 路径预检。** 新增无副作用的 `socketPathError`，daemon 通过包子路径导出给 CLI 共用。检查实际传给 Unix socket 的 `<home>/run/devpanel.sock` 的 UTF-8 字节长度，macOS 的 `sun_path` 容量 104 字节，预留一个结尾 NUL 后路径最多 **103 字节**；Linux 容量 108、路径最多 107。macOS 的边界与中文多字节路径均有测试。CLI `daemon start` 在连接探测、创建目录/daemon-start.log 和 spawn 之前检查；daemon `startServer` 在创建数据目录、锁、Manager 和监听 socket 之前也检查，直接运行 devpaneld 同样得到明确提示。

过长时 CLI 返回 `BAD_REQUEST`（退出码 2），正文说明实际字节数、系统限制、NUL 预留和“缩短 DEVPANEL_HOME”，不再要求用户从 daemon-start.log 猜测 EINVAL。检查不自动截断、不迁移数据、不改 socket 位置；现有发现与连接协议不变。

回归先红后绿：真实 HTTP 注册短 secret 后项目名曾为 `fi[REDACTED]ture`；真实 CLI 长 HOME 曾退出 1 并返回通用启动失败。修复后分别恢复原项目名/pathUsed/事件、正确隐藏 secret 字段与运行命令，以及启动前退出 2 且不创建日志/锁/数据目录。额外覆盖整值与 7/8 字符门槛、正则特殊字符、重叠秘密、严格日志、macOS/Linux 字节边界。

验证：新增 7 项回归覆盖两处修复。最终全仓 `pnpm test` **132/132** 通过（40.65s；daemon 39、CLI 16、UI 52、mock 25）；全仓 `pnpm typecheck` 通过（7.61s），后端两包 build 通过（1.65s），`git diff --check` 通过。首轮全仓运行有两项因 120 秒超时取消（实际耗时报告 434/327 秒，无断言失败），不能算通过；这两项单独复测 8.40 秒通过，随后完整复跑全部通过。未认定首次超时的具体原因，也未放宽超时配置。测试均使用临时数据目录，无真实项目或真实 DevPanel 数据变更。


### macOS 按 PID 内存采集调研（2026-10-20）

本次仅排查与研究，未修改资源采集实现或冻结契约。用户第一张截图显示 `内存 2.83 GiB（RSS 估算）· 2 个进程`；后续截图补充 DevPanel 约 123 MiB，而 Activity Monitor 的 PID 63170 为 1.04 GB、PID 63248 为 2.07 GB。后续对照与下面的本机采样吻合，确认主要问题是 RSS 与 footprint 的指标口径差。

**系统数据与口径。** 已知 PID 可以直接查询系统维护的内存计数，不需要根据 CPU、运行时间或 JVM 参数推算。RSS 和 footprint 是不同指标：Apple 解释 resident size 包含可重新从磁盘加载的 clean 映射；footprint 主要归集 dirty、compressed/swapped 等由进程承担的内存，压缩/换出仍按未压缩大小计账。两者大小关系不固定。Apple 同时明确说 macOS Activity Monitor 能看到 footprint，并演示 `proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, ...)` 读取 `ri_phys_footprint`；这支持选用 footprint，但不代表所有 macOS 版本、所有 Activity Monitor 列/分组和任意时刻都会与我们的进程树总和完全一致。[Apple WWDC22：Profile and optimize your game's memory](https://developer.apple.com/videos/play/wwdc2022/10106/)

**开源实现核对。** 以下链接固定到本次联网读取的提交；psutil 内容来自当前开发分支，不能据此假设旧版安装包已有相同接口。

| 项目 | macOS 实现 | 对 DevPanel 的启示 |
| --- | --- | --- |
| pidusage | Darwin 后端选择 `ps`；批量读取 `etime,pid,ppid,pcpu,rss,time`，RSS 乘 1024 转成 bytes。[源码](https://github.com/soyuka/pidusage/blob/bf396c80d6efdd1edc5a524ab6ef51458651a361/lib/ps.js#L37-L109)、[平台选择](https://github.com/soyuka/pidusage/blob/bf396c80d6efdd1edc5a524ab6ef51458651a361/lib/stats.js#L19) | 引入此库仍得到 RSS，不能靠换库解决 footprint 口径差 |
| systeminformation | `ps -axo ... rss ...`，解析后直接返回 `memRss`（ps 的 KiB 数值）；processes 查询有 500 ms 缓存窗口。[源码](https://github.com/sebhildebrandt/systeminformation/blob/292900669623249b3f0f4c8a84548960a4c76e08/lib/processes.js#L835-L852)、[解析](https://github.com/sebhildebrandt/systeminformation/blob/292900669623249b3f0f4c8a84548960a4c76e08/lib/processes.js#L608-L711) | 同样是 RSS；接入时尤其不能把 KiB 当 bytes |
| btop | `proc_pidinfo(..., PROC_PIDTASKINFO, ...)`，内存取 `pti_resident_size`。[源码](https://github.com/aristocratos/btop/blob/4792b0700e617cb2ee5ffbced50c1e52528b912a/src/osx/btop_collect.cpp#L1873-L1878) | 原生调用省去 ps 文本解析，但所选字段仍是 RSS |
| htop | 同样读取 `PROC_PIDTASKINFO`，`pti_resident_size / 1024` 用于 RES；MEM% 也基于 resident size。[源码](https://github.com/htop-dev/htop/blob/394b4a3fc0df593a00be452a1862057b88b4eaf7/darwin/DarwinProcess.c#L413-L443) | RES 与 Activity Monitor 的 footprint 不能直接视为同一个数 |
| psutil | RSS 读取 `pti_resident_size`；当前 `proc_memory_extras` 额外用 `proc_pid_rusage` 取 `ri_phys_footprint`，先 V4，不支持时回退 V0。[源码](https://github.com/giampaolo/psutil/blob/a625dc49c900f03283cf95d611aa3dbd8ae43b49/psutil/arch/osx/proc.c#L269-L324) | 已有轻量原生 API 的开源先例，不需要扫描完整 VM 映射才能读 footprint |

**单位、权限和轮询。** Apple XNU 将 `phys_footprint` ledger 单位定义为 bytes，rusage 从该 ledger 读数；不是页面数，不应再乘页大小。[单位定义](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/task.c#L1297-L1302)、[rusage 取值](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/bsd_kern.c#L1274-L1277)。`proc_pid_rusage` 走同用户/权限检查及系统安全策略；本项目由同用户 daemon 启动的子进程可以优先直接采样，无需设计 sudo 常驻服务；进程退出或权限不足必须返回不可用，不能伪装成 0。[调用检查](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/proc_info.c#L3820-L3838)、[权限规则](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/proc_info.c#L3161-L3202)。实时监控通常是定时采样；btop 默认 2000 ms。[配置](https://github.com/aristocratos/btop/blob/4792b0700e617cb2ee5ffbced50c1e52528b912a/src/btop_config.cpp#L384-L385)。针对 DevPanel 的工程建议是沿用约 1–2 秒的全局采样周期、批量查询已验证身份的受管 PID、复用同一快照；这是本项目建议，不是系统 API 的硬性频率要求。

**本机只读对照。** 主调查在 2026-10-20 23:55:25 +08，以本机 SDK 校验结构后用 ctypes 调用 `proc_pid_rusage(RUSAGE_INFO_V0)`，无 sudo，两次调用均成功返回 0；各 PID 调用前后的 `ps lstart` 一致。实际 `scanProcesses` / `discover` / `resourceSample` 路径也确认是同一棵两进程树。仅查询 OS 进程信息，未读写真实 `DEVPANEL_HOME`，未启动、停止或注册项目。

| PID | 进程 / 启动时间（+08） | Resident bytes | Footprint bytes |
| --- | --- | ---: | ---: |
| 63170 | java / 23:52:25 | 18,989,056 | 1,119,192,720 |
| 63248 | java，63170 的子进程 / 23:52:30 | 107,413,504 | 2,224,949,840 |
| 合计 | 2 个进程 | 126,402,560（120.55 MiB） | 3,344,142,560（3189.22 MiB，约 3.11 GiB） |

该采样与第一张截图约 23:52:39 不同刻，不能拿这组数据反推第一张截图的 2.83 GiB 是否算错。用户后续截图的两个 Activity Monitor 数值，与本次两个 footprint 分别按 GiB 换算后的约 1.04、2.07 相符；DevPanel 约 123 MiB 与采样 RSS 合计约 120.55 MiB 接近，少量差异可来自采样时点。这确认了指标口径差：整项服务的 footprint 合计应约 3.11 GiB，而不是只看根 PID。此次没有直接采集压缩量，不能把两个指标的差额全算作已压缩内存。footprint 不是 JVM heap used，不能拿堆内存或 `-Xmx` 当作其精确对应值。

**后续建议。** 若产品希望“内存”更符合 macOS 用户的日常观察，应评估以 `proc_pid_rusage` 的 `ri_phys_footprint` 作为 macOS 主指标，保留 RSS 的独立语义；daemon 可调用随包构建的轻量原生 helper，避免依赖用户安装 Python，也避免每个 PID 单独启动一次 `ps`。界面需说明主 PID/整个受管进程树的统计范围。跨进程相加仍不是全机物理页面去重后的净占用；采样需校验 PID 与启动身份并处理退出竞态。由于现有契约写的是 RSS，不能把 footprint 静默塞进 RSS 字段；新增/切换指标需另走契约提案和确认流程。本次没有执行该变更，也没有创建待决契约提案。


### footprint 与进程采样优化落地（2026-10-21）

用户在上述调研和性能说明后确认实施。契约同步增加可选 `footprintBytes`，保留 `rssBytes` 原语义；接口/CLI 旧客户端继续可用，旧 mock/daemon 缺省该字段时原生界面明确标注 RSS 回退。任何进程 footprint 未读到都不发布部分合计，未知值不填 0。

**实现。** `native/process-sampler.c` 是一个由 Manager 拥有的轻量请求驱动 helper：`S` 请求通过 `sysctl(KERN_PROC_ALL)` 读取 PID/PPID/PGID/启动时间和短进程名（无参数、无环境）；`R` 请求仅批量读取已核验的受管 PID。`proc_pid_rusage(RUSAGE_INFO_V0)` 同时给出 resident、footprint、CPU 时间；读取前后检查 `PROC_PIDTBSDINFO` 的启动秒/微秒及僵尸状态。对外身份保持原 `ps lstart` 的秒精度，兼容既有运行记录；不改归属/逐 PID 信号规则。CPU 用 `mach_timebase_info` 把 Mach ticks 换成毫秒，不能假定 Apple Silicon 上原始值就是纳秒。

`ProcessScanner` 串行化请求并复用一个 helper，进程发现仍为约 250ms，资源查询沿用默认 2s，监听端口后的身份复核也走同一 helper。helper 无自主轮询，没活动运行时不发送查询；Manager 关闭或 daemon 消失后通过 stdin EOF 退出。原生构建/启动/协议错误或 200ms 查询超时会关闭通道，退避 30s 后自动重试；退回 `ps`，常规发现间隔仍为 250ms，显式启动/停止操作仍立即扫描。资源读取失败当次返回未知，不重用旧数据。端口查询仍使用原有批量 lsof，未扩大范围。

`native-build.ts` 检查源码和二进制时间戳，使用系统 xcrun/clang 原子构建本机二进制；`pnpm build`、`setup:cli` 后台预编译，daemon 初始化同样异步预热。服务启动和扫描不等待 clang，未就绪先走 ps，构建失败 30s 后可重试，无 npm 新依赖。构建失败可退回 RSS 管理流程。二进制在 `native/build/`，已忽略；无 Python 运行时依赖。`DEVPANEL_PROCESS_BACKEND=ps` 可在隔离开发运行时强制检查回退。

**整体验证与性能。** 全仓 `pnpm typecheck`、`pnpm test` **136/136**（daemon 43、CLI 16、UI 52、mock 25）通过；新增后端测试验证 helper 复用、原生/ps 身份一致、Mach CPU 单位、身份不匹配不归属资源、EOF 退出、故障回退、完整/缺失 footprint 汇总。现有集成测试继续覆盖 detached 后代、停止超时/强制停止、崩溃恢复和重复启动保护，并新增真实 HTTP footprint 断言。Swift `build` 和 **231 项测试**通过，新增 5 项解码/透传/显示优先级/RSS 回退/未知值测试。daemon/CLI build、release `.app` 打包及签名校验通过；`git diff --check` 通过。

隔离真实 daemon 启动三进程树，release 界面总览和检查器都显示 footprint 合计；截图 `.devpanel-dev/codex/memory-footprint.png`，REST/采样记录 `memory-ui-result.json`。验收后用受管身份正常清理，未连接或重启真实用户 daemon。

性能比较使用三个相同的空闲 Node 服务，预热 3s 后测 15s。基线是修改前 HEAD 的 daemon 源码隔离副本，优化版为本次源码；完整 daemon 包含 HTTP/Unix 服务器，无 UI 客户端流量。通过 `proc_pid_rusage(V2)` 差值统计 daemon 自身、期间已回收的 ps/lsof 子进程及存活 helper；按本机 Mach timebase 125/3 转换，**100% = 一个逻辑核心**，不计仍存活的业务服务 CPU。CPU 与内存均为本机短时样本，不是长期保证或全机器百分比。

| 完整 daemon，3 个空闲服务 | 修改前 | 修改后 |
| --- | ---: | ---: |
| daemon 自身 CPU | 2.40% | 0.71% |
| 已回收采样子进程 CPU（ps/lsof 等） | 32.24% | 1.80% |
| 存活原生 helper CPU | 无 | 0.40% |
| **管理侧合计 CPU** | **34.64%** | **2.91%** |
| 原生 helper RSS | 无 | 2.05 MiB |

完整 daemon 本轮约下降 **91.6%**。较早的 Manager 核心对照为 23.10% → 3.17%（下降 86.3%），系统负载/窗口不同导致绝对数值波动；两轮都显示反复启动全机 ps 是主要可削减成本，不能用单次系统 API 的微秒耗时冒充整体收益。原始记录和复测脚本保存在 `.devpanel-dev/codex/memory-perf{,-full}-{before,after}.json`、`memory-perf.mjs`、`memory-perf.py`。本次没有替用户安装应用或重启真实管理服务；新版需在停止项目后重启 daemon 与界面生效。

### 工具自身资源可见性（2026-10-21）

用户进一步要求工具与辅助进程的占用全部可见。新增 `DaemonInfo.toolResources` 的管理进程、辅助进程、后台合计三个样本，保留 `self` 的纯管理进程语义。原生界面底栏显示完整工具合计，点击显示界面/管理/辅助三项；业务项目不计入。此处的工具范围是当前界面实例和连接的后台，不聚合其他单独启动的 DevPanel 界面。

本节覆盖上节中“空闲不查询”和“仍使用 lsof”的实现描述：管理进程现在即使无项目也每 2 秒发送 `O`，helper 仅采样自己的 PID 与父进程 PID，无全机扫描；有活动项目时仍共享已有发现/资源周期。`P` 使用 `PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO` 查询已核验受管 PID 的 TCP LISTEN，读取后复核秒/微秒身份。失败返回未知，确认没有端口才返回空列表。macOS 正常路径不再周期启动 ps/lsof，从而也消除短命采样进程难以完整归入工具资源的问题。回退路径保留旧端口查询，但辅助/后台合计返回 unavailable，绝不把仅 daemon 的数值冒充整个后台。

界面通过 `proc_pid_rusage(getpid())` 自采样，每 2 秒调用一次缓存的 `/daemon`，1.5 秒 HTTP 超时不阻塞本地采样。采样器随 AppModel 生命周期唯一持有，连接 generation/PID/启动时间拒绝旧连接的回复。首次 CPU 未知；断连、缺失、partial 或超过 6 秒的样本不用于完整合计；footprint 和 RSS 分开求和。CPU 的 100% 表示一个逻辑核心，前后端区间都用系统累计 CPU 差值，不是瞬时峰值。

**验证。** 全仓 typecheck 通过，测试 138 项通过（daemon 45、CLI 16、UI 52、mock 25）；Swift 242 项测试通过。新增原生无全机发现的自身采样、精确 owner+helper 范围、IPv4/IPv6 监听/关闭/身份不匹配测试；空闲真实 daemon 验证两进程 CPU、footprint 可加性。Swift 覆盖完整/缺失/旧版本/过期/混合口径与生命周期。最后补充 FD 读取的 errno 检查后重新通过全部 6 项 native scanner 测试。daemon/CLI build、release app 打包与签名检查通过。

同上节完整 daemon 基准，三个空闲服务、预热 3 秒、采样 15 秒，本轮管理进程 0.614% + helper 0.396% = **1.010% 单核 CPU**，期间已回收采样子进程 CPU 为 0。helper footprint 1.31 MiB；后台 footprint 合计约 50.05 MiB。数据见 `.devpanel-dev/codex/tool-perf.json`。这是无 UI 客户端流量的后台短时样本，不代表整个 APP 的 CPU 或各种负载下的保证。

真实 release UI 隔离联调见 `.devpanel-dev/codex/tool-resources.png` 和 `tool-ui-result.json`：持续输出日志的三进程树下，界面 43.3 MiB + 管理 43.2 MiB + 辅助 1.7 MiB = 工具合计 88.3 MiB；业务进程树单列约 40 MiB。此时日志界面 CPU 22.1%、工具总 CPU 24.6%，如实显示 UI 工作负载，不应将后台的 1.0% 基准当作整机工具开销。另有空闲服务界面验收 `tool-resources-idle.png` / `tool-ui-idle-result.json`：三项工具合计 76.22 MiB、4.55% 单核 CPU（短时 UI 样本，非后台基准），业务服务 13 MiB 另列。两组真实 UI 输出均程序化核验 CPU/RSS/footprint/进程数合计等于界面+管理+辅助。均使用临时 DEVPANEL_HOME，测试进程已清理。

本轮交付是完整工具资源显示与采样优化；将 Node/后台封装入单一 `.app` 并自动启动的发布形态尚未实现，当前 bundle 仍是原生界面，不能据此声称已经无需独立后台。

### v0.2 收尾：采样故障恢复（2026-10-21）

- helper 超时/退出/协议错误后关闭管道，30s 退避不因中途轮询延长；到期按需重新创建 helper。显式 `DEVPANEL_PROCESS_BACKEND=ps` 仍保持 ps。
- 编译只在后台进行；待编译与故障回退都保持 250ms 发现周期。忙碌的 helper 不阻塞发现，改走 ps；身份仍逐 PID + 启动时间核对。
- 回归：真实子进程第一次请求不响应，超时返回 ps；测试时钟 29,999ms 仍回退，30,000ms 恢复新 helper（改前实际失败，返回 node 而非 recovered）。编译 Promise 未完成时扫描先返回，之后恢复原生；编译失败后也能重试。
- ps fixture 在初次扫描后才派生 detached 子进程，父进程 900ms 后退出；核验子进程已重新挂父仍被记录，停止后身份消失。轮询无法承诺捕获任意小于采样窗口、已完全脱离谱系的进程，原有前台命令边界不变。

### v0.2 收尾：真实 LISTEN 测试间歇失败（2026-10-21）

旧 fixture 从非受管 `::1` / `ipv6Only` 监听获取随机端口，再让受管 `127.0.0.1` 服务绑定相同数字。IPv6-only 并未预留 IPv4；后者可能已被占用。对原测试只加入同号 IPv4 占用即可稳定得到 `partial != succeeded`，服务日志为 `listen EADDRINUSE`、exit(1)，而另外两个服务正常启动。由此排除本次复现是 LISTEN 采样器把数据读错或启动等待不足。

修复为受管服务直接 `listen(0)`，由系统原子分配，再从该运行的日志取真实端口交叉核对 stats。持续持有独立 IPv4 与 IPv6 非受管监听，断言它们既不进入服务统计、停止后也仍存活；失败时附逐服务结果与 fixture 日志，不再只留下 partial。

证据：`.devpanel-dev/codex/closeout/listen-red.log`（改前症状与 EADDRINUSE）、`listen-green.log`（改后通过）；并复跑 native/ps 各 10 次。没有放宽 succeeded 断言或增加启动重试/等待。此前 `d-first-failed-pnpm-test.log` 没有服务日志，不能倒推证明那一次必然是同一原因；本次确定复现并修复的是可产生完全相同断言的端口预留缺陷。


# v0.3 实现与验证（2026-10-21）

## v0.3 快捷操作与通用任务运行

`manager.ts` 在原有运行记录中保存任务元数据，并复用服务的 spawn、启动快照、进程身份与后代追踪、取消、日志、资源采样和恢复流程。内部用 `action:<id>` 与 `maven:` 区分任务槽位，避免与用户服务 ID 冲突。对外通过 `TaskRunSummary` / `TaskRunDetail` 提供任务语义：运行中、取消中、成功、失败、已取消、超时和无法核验；取消等待超时保留 `cancelTimedOut`，继续跟踪存活进程。退出码 0 的正常结束为成功，执行超时最终记录 `timed-out` 与 `exit.reason=timeout`。

同一快捷操作的重复运行请求复用当前运行，不同快捷操作可并行；同项目 Maven 只允许一个运行。任务有独立的启动/取消并发控制，活动任务阻止删除所属操作或项目。每个快捷操作及每项目 Maven 各保留默认 5 次运行，单次日志默认上限 16 MiB，沿用总日志上限、敏感值遮盖和序号预留。`ProjectStats.tasks` 按 runId 返回活动任务资源，项目合计按进程身份去重，任务结束后不继续保留活动资源。

`config.ts` / `params.ts` 将动作纳入原有静态校验、敏感值保持和引用处理，`usedBy` 使用 `action:<id>`。命令与环境在启动时按当前选项展开，保存动作不会执行命令。重启恢复核验存活身份，不自动重跑；无法恢复管道的存活运行保留 unknown 语义。CLI 新增 `action list|run`、`task cancel`，`logs --run` 可以读取任务日志。

## v0.3 Maven 静态模型与命令

`maven.ts` 只读取项目内 POM，使用 `fast-xml-parser` 静态解析嵌套 modules、坐标、parent 中的 groupId、缺省 jar packaging 与 profiles；不启动 Maven、不联网、不读取 `~/.m2`。模块按深度优先返回，单模块读取/解析错误留在模块行，不使其他模块消失；外部父 POM仅作标注，不跨项目读取。DTD、实体声明、越界模块及循环引用受到限制，单个 POM 限 2 MiB。

模型缓存记录相关路径的 realpath、mtime、ctime 和大小；缺失 POM 也记录 missing，以便文件补齐后失效重读。`reload=1` 强制重建。项目根没有 POM 返回 `MAVEN_UNAVAILABLE`。模型按请求计算，没有后台文件监听或周期解析。

`auto` 优先可执行 wrapper，否则在有效 PATH 查找 mvn；`wrapper` / `mvn` 可明确选择。daemon 只接受 moduleId、goals、profiles、skipTests、offline、alsoMake，校验后构造 argv，在项目根和项目环境中运行。子模块附 `-pl`，按请求加入 `-am`、`-DskipTests`、`-o`、`-P`，再追加 goals。无效模块、goal/profile 或多余字段返回 `MAVEN_INVALID`；以 `-` 开头的 goal 额外拒绝，契约说明待用户确认。CLI 提供 `maven modules|run`，执行进入通用任务托管。

## v0.3 Git 后端

`git.ts` 按项目根定位 Git 工作树，解析 porcelain v2 的 NUL 分隔输出，保留空格/中文路径、重命名原路径、暂存/工作区两侧状态、冲突、未跟踪、上游偏离与敏感文件名标记。status 最多 5,000 条。diff 支持暂存/未暂存、有限或整文件上下文，最多 5,000 行或 2 MiB；二进制返回大小。未跟踪符号链接显示链接文本，不读取目标内容；冲突工作区以 ours 比较，尚无合并结果的暂存区明确返回说明。

写操作按实际仓库根串行化。stage/unstage 使用字面路径，重命名同时处理新旧路径；commit/amend 检查 expectedHead，失败后复核 HEAD，把提交期间的移动映射为 `GIT_HEAD_MOVED`。已有 index.lock 返回 `GIT_LOCKED`，不删除它。Git trace2 用于识别真实钩子失败，过滤内部 trace 后返回钩子输出；普通 Git 失败不会冒充钩子失败。stash apply/pop 产生冲突时返回 `GIT_CONFLICT`，保留储藏。

所有写路由仅接受 `X-DevPanel-Client: ui`，CLI、缺失或无效客户端头均返回 `FORBIDDEN_CLIENT`；CLI 没有 Git 命令。路径拒绝绝对路径、`..`、仓库外符号链接及 Git 内部文件。非仓库 status 返回 repo=null，其余操作明确失败；找不到 git 返回 `GIT_UNAVAILABLE`。没有丢弃改动、删除储藏、分支切换或远端操作。

Git 子进程使用 argv、`LC_ALL=C`、禁用交互提示；只读命令带 `GIT_OPTIONAL_LOCKS=0`，diff 禁用外部 diff/textconv。查询限时 10 秒，提交 120 秒。运行前 2 秒每约 50ms 追踪，之后约 250ms；超时只向已核验身份发 SIGKILL，并等待这些身份退出（有界等待）。`Git.close()` 等待已有命令和写队列完成，Manager 随后关闭采样器，避免清理抢先结束。Git 状态按请求查询，不在 daemon 内轮询文件系统。

## mock 与兼容范围

mock 以同一任务生命周期承载快捷操作与 Maven。order-service 含 3 个动作，以及根模块、backend、contracts、外部父 POM 模块、解析失败模块；输出包含 reactor、插件段、WARNING、成功/失败。内存 Git 覆盖各分组、敏感文件、二进制、长文件和两个储藏，可确定性模拟锁、钩子失败、HEAD 移动、储藏冲突、无 git、非仓库。`POST /__mock/git/:id` 的这些调试模式只属于 mock。旧 Web UI 仅补齐新增必填字段并通过既有测试，没有新增 v0.3 产品功能。

## 安全边界与测试进程清理

本轮测试使用临时 DEVPANEL_HOME、短 socket 路径和临时项目；Git 写入仅发生在临时仓库，Maven 测试使用不会下载依赖的假 wrapper。没有使用稳定版命令入口，没有修改稳定版目录或 `/Applications/DevPanel.app`，没有重启或停止用户 daemon。注册、更新和校验均不执行项目命令。

已复现的旧测试清理漏洞位于 `packages/daemon/test/integration.test.ts` 的公共 cleanup：原先依赖 HTTP force-stop；若 HTTP 已关闭，停止请求失败后 `Manager.close()` 按产品语义保留业务进程，删除测试目录并不能结束 silent fixture。修复是在停止前保存本次运行的 pid+启动时间，HTTP 失败时按身份核验强制清理，并等待/assert 已退出后才关闭服务器和删除目录。独立同名 fixture 的清理钩子也提前注册，独立 daemon 的清理增加退出确认。

新增回归先启动 silent fixture，再关闭 HTTP，确认进程仍活着，然后执行 cleanup；旧实现断言 `silent fixture survives failed HTTP force-stop` 失败，修复后通过。这证明并修复了一个确定的漏清理路径，但历史遗留进程已消失，不能据此声称已唯一定位当年那个 PID 来自哪一次测试。

Git 超时另有独立回归：假 git 在 100ms 后派生 detached 子进程，200ms 后父进程退出；子进程继续持有管道。旧的 1 秒追踪错过该子进程，超时返回后仍残留；当前更快追踪与超时等待能捕获并清理这一场景。fixture 独立记录真实 pid+启动时间，红测试的兜底清理也先核验再发信号。不得以 `--test-force-exit` 代替业务子进程清理。

身份核验仍有操作系统级竞态，采样也不能保证捕获任意瞬时 double-fork、完全脱离父链/进程组且从未被看见的进程。更快采样只缩小窗口，不构成原子进程归属保证；无法核验身份时不发信号。进程管道与崩溃恢复的原有限制继续有效。


完整阶段测试、真实 POM 副本/临时仓库验收、资源测量与截图索引见 [v0.3 计划与验收](plan-v0.3.md)。冻结契约的四项限制见 [待决提案](../contract/CHANGES.md)：任务日志结束载荷、Maven goal 前缀、Git 钩子实时输出、差异版本指纹。未修改 api.md 或共享类型。

开发只使用隔离 `DEVPANEL_HOME` 和 `node packages/cli/src/main.ts`；本文件早期默认 `setup:cli` 示例仅是用户安装历史说明。开发安装必须显式传入临时 `--bin-dir`，不得覆盖稳定版入口。

### v0.3 review：任务模块边界

`task-runs.ts` 负责显式 action / Maven 目标、并发与取消调度、任务摘要、历史；`manager.ts` 保留任务与服务共用的进程身份、spawn / stop、日志与采样。服务查找排除任务记录，任务不再用 serviceId 的前缀判断归属。旧的磁盘任务元数据在读取时迁移为显式 target；日志 end 返回真实任务摘要，服务详情路由不投影任务。任务 lastRun 只选已结束记录。


### v0.3.0 高负载原生采样故障修复（2026-10-21）

本节覆盖前文 200ms 超时、单次失败即回退与固定 30s 重试的旧行为。可重复回归：Node helper 延迟 500ms 响应 `S`，旧实现约 262ms 已返回 ps 的 `node` 行，断言期望原生 fixture 行失败。另一个入口是在 helper 忙时跳过请求队列，直接用 ps；并发慢响应测试一并覆盖。

- 查询超时默认 2000ms；`S/R/O/P` 共用串行请求队列，忙时排队。完整协议及字段校验成功后才重置失败计数；无效 JSON、无效行、退出、I/O 与构建失败均记录类别。单个事件只计一次，排队调用及退避期间的轮询不增加次数、不推迟重试。
- 连续 3 次失败后才启用 ps/lsof 回退；每次失败从结束时刻起等待 2、4、8、16、30 秒，随后封顶 30 秒。下一次调用到期重试；任一有效响应重置计数和退避。原生尚未构建完成、非 macOS 或显式 ps 模式仍保持原有回退。
- 前两次失败时，进程身份扫描抛出暂时不可用，Manager 将展示样本标为 partial。历史 RSS 保留原 sampledAt，CPU/footprint 与端口置未知；helpers/total 不立即变 unavailable。没有把旧 PID 快照交给停止、退出判断或 Git 子进程清理；身份无法重新核验时不发信号。达到阈值后 helpers/total unavailable，恢复后的首个 CPU 样本仍为 sampling。
- 每个 Manager 将诊断写入其 `DEVPANEL_HOME/daemon.log`（新建文件权限 0600），因此 launchd 丢弃 stderr 时也能保留日志。JSON 行包含 UTC 时间、事件、原因、该原因累计次数、连续失败次数、retryMs；退出有 exitCode/signal，超时有 timeoutMs。相同事件/原因 30 秒内限流，后续记录带 suppressed 次数；首次降级和恢复分别记事件，恢复反复抖动也限流。只写固定类别与数值，不转发原始输出、环境、错误文本或路径；关闭 helper 不记故障。

**自动验证。** 全仓 `pnpm typecheck`、`pnpm test` 与 daemon `build` 通过：192 项（daemon 79、CLI 16、mock 45、Web 52）。其中采样器 13 项覆盖四种请求的 500ms 响应、并发队列、三次失败阈值、2/4/8/16/30 秒退避、轮询不改变重试时刻、恢复重置、退出码、无效 JSON/行、日志落盘/权限/限流/恢复以及 Manager 的 partial → unavailable → sampling → ok 状态。测试均使用临时 DEVPANEL_HOME，未更改契约。

**高负载实测。** 本机 10 逻辑核、Node 24.21.0；启动当前源码的隔离 HTTP daemon（127.0.0.1 随机端口）及 12 个有界 CPU fixture，每个忙循环 35 秒，实际合计约 **878.33% 单核 CPU**。预热后观察 30 秒，每约 250ms 调用同一 scanner 的 S/R/P，Manager 同时正常每 2 秒采自身 O。120 轮全部原生，**0 次失败、0 次 ps 回退、0 次缺失 footprint**，helpers 状态全部 ok，helper PID 始终相同（92587）。每轮 S/R/P 总耗时中位数 2.15ms、P95 2.69ms、最大 11.45ms；未产生故障日志。CPU fixture 自行退出，daemon 正常 close、helper EOF 退出，按保存的 PID+启动时间复核无残留，没有向用户进程发信号。

这是短时 CPU 压力验证，另以 500ms fixture 确认慢响应路径；未把它当作两 JVM + Next.js 的长时间内存/调度压力保证。原始脚本及结果保留在 `.devpanel-dev/codex/sampler-recovery/high-load.mjs`、`high-load-result.json`、`high-load.log`；全仓测试记录为 `/tmp/devpanel-sampler-full-test.log`。仅本地 main 提交，不推送、不打标签、不修改稳定安装和真实 daemon。

## v0.4 独立发布包

`scripts/release.mjs` 生成本机架构的 App、ZIP 与 SHA-256，只写仓库 `.devpanel-dev/`。采用 Node 官方独立运行时 24.21.0（下载后核验官方哈希），内置 CLI、daemon、共享类型源码、生产依赖和原生采样器。Node 24 原生运行 TypeScript；workspace 包采用相对链接，避免 node_modules 内 TS 剥离限制。没有选择本机 Homebrew Node，因为它依赖 Cellar/opt 动态库。初始安装阶段 App 约 131 MiB、ZIP 约 42 MiB，最终体积与哈希以 [v0.4 验收记录](plan-v0.4.md) 为准。

命令 wrapper 解析自身软链接后定位内置 Node，移动到含中文/空格目录仍可使用。App 无 DEVPANEL_HOME 时优先包内 CLI，隔离开发保持旧启动器行为。嵌入 Mach-O 先 ad-hoc 签名、再签外层，随后严格验证；不做开发者签名、公证或公开发布。`scripts/release-smoke.mjs` 在不含 Node 的 PATH、临时 HOME/DEVPANEL_HOME、仓库外 App 副本中验证注册、业务日志遮盖、启停与进程清理。稳定版迁移步骤见 [发布说明](release-v0.4.md)，开发不执行迁移。

## v0.4 AI 闭环与监督

`activity.ts` 统一解析/校验请求来源，CLI 参数优先于 DEVPANEL_AGENT，ui 忽略自报名称；Operation、服务/任务启动方和停止/取消方持久化，旧记录读 null。按终态和配置保存写入项目动态，每项目保留 500 条；配置差异共用注册冲突的生成器，100 条截断、敏感项统一 `{secret:true}`，分页和项目删除均在存储层处理。新增响应字段在 v1.3 daemon/mock 中总是返回，客户端继续兼容可选解码。

`policy.ts` 独立保存规则与暂停，不进入 ProjectConfig。CLI 拒绝发生在服务队列入队及停止优先之前，执行前再次检查，防止界面停止与 CLI 启动竞态；被拒 stop 不取消启动。锁定优先于 overrideHold；越过成功才清除暂停并标记动态。规则写入和解除暂停仅 ui，默认 holdAfterUserStop=true、agentForceStop=deny；它们用于防误操作，不是认证或安全边界。

`digest.ts` 每请求遍历有界已脱敏日志，不缓存、不把日志文件整体解析为大对象。识别、数字签名去重、Java/Python 堆栈折叠、UTF-8 截行和预算按 §14；服务/任务共用路由。`test-fixtures/digest/` 是 TypeScript CLI 与 Swift 格式化器共读的 golden 输入与期望文本。32 MiB 上限实测保留 33,552,103 bytes / 8,054 行，摘要 6.36ms、blocks 1,173 bytes；不包含预先日志采集耗时，不能视作所有日志分布的上界。

`ready.ts` 管理一次性就绪状态；启动时快照文字/端口与选项值，排除于进程配置变更比较。日志采集路径只做有界子串匹配，sys 不参与；采集器用 KMP 前缀表仅保留可能续接敏感值的后缀，避免最后一行 READY 被固定缓冲吞住。等待端口复用 scanner 原生 LISTEN 查询，离开 waiting 后不再额外读取；超时只标记、不停止。长轮询支持服务运行，任务明确 400。已有 §8 恢复不能接回旧管道，等待恢复为 unknown，已就绪保持；不假装已续接。

CLI 的 --wait-ready 返回 CliStartReport，失败附摘要，退出码按契约优先级；未配置就绪仍可为 0，提示写 stderr。secret 环境/选项的回归覆盖启动报告、动态、日志和摘要。冻结契约正文/类型未修改，三个按任务说明先采用的解释记在 [待决提案](../contract/CHANGES.md)。整合、真实框架、资源与进程审计见 [v0.4 验收记录](plan-v0.4.md)。

## 四轮优化（2026-10-25，v1.5-A/B/C 已确认）

`log-search.ts` 直接遍历有界保留日志，返回有上限的命中及上下文；普通文本匹配前去 ANSI，结果继续使用采集时已脱敏的原文。分页用固定 throughSeq 和排他 after，不把实时新日志混进旧快照；即使保留区已全部淘汰，也用分配序号保持搜索上界。mock 使用独立实现，原生只保留当前搜索页。共享语义/类型和原生/CLI 的输入校验保持一致。

CLI `portable-config.ts` 负责可分享文档与受限标量输入，`portable-commands.ts` 负责已有配置 API 的编排。默认预览，显式 apply；更新必须使用预览 revision，不重试冲突，继承用户参数保护。导出拒绝覆盖，secret 值和本机路径转为必填输入，输入文件有大小/普通文件限制，预览仅显示差异字段和输入元数据。导入不增加执行路径。仓库文件同步规则见 [配置分享](config-sharing.zh-CN.md)。

工作上下文在 requestActor 校验并解码，Manager.actor 在写入运行、操作、配置动态前严格遮盖已知 secret（包括短子串与本次新配置的秘密）。UI/daemon 不接受 CLI 工作上下文。动态在原项目游标之后筛选再 limit，确保稀疏任务分页正确。instance 仅进入配置与视图显示；真实 root 仍唯一，进程、日志、托管规则继续按 projectId 隔离。

打包内置快速开始、skill、可生成 demo 和可分享示例。来源清单记录 Git 提交、dirty 状态和输入文件哈希，构建期间来源变化会拒绝产出。最终包 smoke 扩展到日志检索、分享/导入预览和显式应用、实例信息和工作归属；所有数据与进程隔离。逐轮结果与目标机器验收限制见 [四轮记录](plan-four-rounds.md)。
