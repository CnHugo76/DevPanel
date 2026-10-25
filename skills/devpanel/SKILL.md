---
name: devpanel
description: 通过 DevPanel CLI（`devpanel`）托管本机项目的长期运行服务。用于：启动 / 停止 / 重启本地服务，查看它的日志或 CPU / 内存；把项目"加入 DevPanel / 面板"（注册）；修改已注册项目的运行配置或选项；运行项目登记的快捷操作或 Maven 目标。
---

# DevPanel

DevPanel 是本机的项目运行面板：常驻的管理服务（daemon）托管项目的长期运行服务。人用面板，你用 `devpanel`，两边操作的是同一份进程、日志和资源。你启动的服务，用户在面板里看得到、能停止；用户停止的，你查询得到。

## 先确认版本

运行 `devpanel --help`。出现 `--wait-ready` / `--digest` 时使用本文件的 v0.4 流程；旧版没有这些开关时，启动后用有限日志与实际端口确认，日志用 `--tail`，不传新参数。出现 `action` / `maven` 时，额外可用 [references/v0.3.md](references/v0.3.md) 的任务命令。

出现 `--maven-project` 时，接入和更新项目还须明确登记 Git 仓库与 Maven 工程（[配置](references/config.md)）；面板只按配置显示目标，不递归猜目录。

在 **Agent 自身环境配置** 中设置 `DEVPANEL_AGENT`（例如 `codex`、`claude-code`）；也可逐条命令传 `--agent`，参数优先。不根据进程名、模型或目录推断名称。没有名称时显示“命令行”；名称用于记录来源，不是认证。

## 托管规则

- 长期运行的服务只经 `devpanel` 启停，DevPanel 是它唯一的启动入口。daemon 不可达（退出码 3）时，向用户报告并停下，建议运行 `devpanel daemon start`，用户同意后再运行。
- 用 ID 定位。项目 ID 来自项目规则文件（`AGENTS.md` / `CLAUDE.md` 中的 DevPanel 段）或 `devpanel project list --json`；名称只用于显示，对应到多个项目时请用户指认。
- 用户主动停止按 `lastRun.exit.requestedBy.client === "ui"` 判断；退出码 9 时停止当前流程并查询取消方。旧 daemon 缺少来源时按未知报告，不猜测。
- 暂停、锁定与 AI 强制停止限制由 daemon 执行，规则只能在界面修改。退出码 12 时报告 `POLICY_DENIED` 的原因；不改配置来绕过。`--override-hold` **仅在用户本轮对话明确要求越过暂停启动时**使用，它不能越过锁定。
- 停止用 `stop`。`stop` 超时（退出码 7）时，报告仍存活的进程数（`error.details.remaining`），由用户决定是否 `force-stop`。
- 构建、测试、lint 等跑完即结束的命令照常在终端运行；DevPanel 管的是长期运行的服务。

## 日常操作

1. **查状态**：`devpanel status <project-id> --json`。看每个服务的 `state`、`ready`、`hold`、`locked`、`error` 和 `configChangedSinceStart`。
2. **启动 / 重启**：`devpanel start|restart <project-id> [--service <id>]... --wait-ready --json`。单服务可省略 `--service`，不带时作用于整个项目。默认等待操作最长 60 秒（`--timeout` 可调）；`--ready-timeout` 单独限制就绪等待，不与 `--no-wait` 同用。已运行服务返回 `already-running`，不会重复启动。停止仍用 `devpanel stop <project-id> [--service <id>]... --json`。
3. **读启动报告**：检查 `operation.results` 和 `services[]` 的就绪结果、用时与行号/端口，失败目标读附带的 `digest`。`running` 只表示进程存在。退出码 0 仍可能是 `not-configured`：向用户说明尚无就绪依据，不能声称业务可用；需要时按 [配置](references/config.md) 补登记条件。
4. **资源**：`devpanel stats <project-id> --json`。数值为 `null` 表示未知，不是 0。

读日志优先 `devpanel logs <project-id> --service <id> --digest --json`，或用 `--run <run-id>` 指定运行（与 `--service` 二选一）。摘要包括错误块、重复次数、上下文和省略情况；记下 `lastSeq`，修改并重试后用 `--digest --after-seq <lastSeq>` 读取同一运行的增量，换运行时重新开始。需要原文时用 `--tail <n>`；普通日志也支持 `--after-seq`。`--follow` 是持续流，只在能主动结束时使用。

启动完成标准：目标操作成功、就绪为 `ready`，再按任务需要验证业务。`timed-out`、`unknown`、`not-configured` 都要如实报告；就绪只是一次信号，不是持续健康检查。

## 退出码

| 码 | 含义 | 接下来 |
| --- | --- | --- |
| 0 | 成功 | |
| 1 | 操作 `failed` 或其他错误 | 读报告中的错误与 digest，必要时再看原文 |
| 2 | 用法错误 / `CONFIG_INVALID` | 修正命令或配置；配置问题在 `error.details.issues` |
| 3 | `DAEMON_UNREACHABLE` | 见托管规则第一条 |
| 4 | `*_NOT_FOUND` | 用 `project list --json` 重新核对 ID |
| 5 | `CONFIG_CONFLICT` / `REVISION_MISMATCH` / `PROJECT_RUNNING` | 见 [references/config.md](references/config.md) |
| 6 | 操作 `partial` | 逐个看 `results[]`，分别处理失败的服务 |
| 7 | 停止超时 | 报告 remaining，等用户决定是否强制停止 |
| 8 | 等待超时，操作仍在进行 | 用输出里的操作 `id` 运行 `devpanel operation <operation-id> --json` 继续查询；这不是失败 |
| 9 | 操作被取消（通常是用户在面板点了停止） | 查询取消方并报告 |
| 10 | 任务执行超时 | 读任务状态与摘要，报告超时；不自动重跑 |
| 11 | 就绪等待超时 | 服务可能仍在运行；读 ready / digest，不自动停止或重启 |
| 12 | 失败目标全部被托管规则拒绝 | 报告拒绝原因；其他目标可能已成功；与一般失败混合时按 6 / 1 处理 |

`--json` 的 stdout 只有结构化结果。`--wait-ready --json` 即使失败也返回 CliStartReport（`operation`、`services`），按退出码和报告判断；请求本身失败仍可能返回 `{ "error": { "code", "message", "details" } }`。

## 接入新项目

用户要求"把项目加入 DevPanel / 面板"时，按 [references/onboarding.md](references/onboarding.md) 操作。注册不会启动项目；用户只要求接入时，到注册完成为止。

## 修改已注册项目

改服务命令、环境变量、选项定义等，按 [references/config.md](references/config.md) 的"更新配置"操作。只改某个选项的值：

```bash
devpanel param list <project-id> --json
devpanel param set <project-id> <key> <value> --json
```

`param list` 里 `setBy` 为 `user` 的值是用户在面板里改的，只在用户要求时才 `param set` 覆盖它。保存配置不会重启服务：运行中的服务会显示 `configChangedSinceStart: true`，告诉用户需要重启才生效，用户同意后再 `restart`。
