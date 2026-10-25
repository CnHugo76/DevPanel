你现在扮演“reg-radar 项目里的编程 Agent”，用真实项目对 DevPanel 做最终验收。DevPanel 仓库：/path/to/DevPanel（基线提交 32823fc）。被接入的项目：/Users/demo/Projects/reg-radar。

## 用户已明确授权
- 用 `pnpm setup:cli` 把 `devpanel` / `devpaneld` 安装到 `~/.local/bin`。
- 使用真实数据目录（默认 `~/Library/Application Support/DevPanel`，不设 `DEVPANEL_HOME`）启动 daemon。
- 把 reg-radar 注册到 DevPanel，并通过 DevPanel 启动、停止它的服务。

## 未授权，不要做
- 不执行 `devpanel daemon install`（不安装 LaunchAgent）。
- 不修改 reg-radar 仓库里的任何文件（包括 AGENTS.md、.env、配置文件），不在 reg-radar 中创建提交。注册用的 JSON 放在临时目录。
- 不停止、不接管任何不是本次 DevPanel 运行启动的进程（包括 IDE、终端里已在运行的服务）。端口被占用时如实报告，由用户处理。
- 不修改 DevPanel 的代码；发现 DevPanel 的问题只记录，不在验收中修。
- 不清库、不重置数据、不调用真实模型。

## 先读
1. DevPanel：`docs/product-design-v0.1.md` 的 §5.1、§7、§11.3、§16；`docs/backend-design.md` 的安装和 CLI 部分。
2. reg-radar：根目录 `AGENTS.md`、`README.md`、`package.json`、`scripts/dev-api.mjs`、`frontend/package.json`、`frontend/AGENTS.md`、`backend/AGENTS.md`。按 reg-radar 自己的规则判断每个服务真实、长期运行的前台启动方式。

## 已知事实（需你自己核实，不要照抄）
- Next.js 前端（frontend/）+ Java 21 Spring Boot 后端（backend/，API 端口 8081，默认 dev profile）；后端依赖 PostgreSQL 和 Redis。
- 根脚本 `pnpm dev:api` 走 `scripts/dev-api.mjs`，会核对 Java 版本；macOS 需要 Java 21 的 JAVA_HOME 和 PATH。
- reg-radar 规定验收前端时先构建、再用 `next start`，不要用 `next dev`。请判断：DevPanel 里登记的前端服务应该用哪种命令，并说明理由。
- DevPanel daemon 的执行环境不继承你当前终端；JAVA_HOME、需要的 PATH 等必须显式写进服务的 `env`。凭据类的值标成 `{secret:true, value}`，并且不要在输出里打印。

## 验收步骤
1. 在 DevPanel 仓库执行 `pnpm install`（如果需要）、`pnpm build`（UI 需要 `apps/ui/dist`）、`pnpm setup:cli`。之后用 `~/.local/bin/devpanel` 调用 CLI。
2. `devpanel daemon start`，再用 `devpanel daemon status --json` 确认。
3. 编写 reg-radar 的 ProjectConfig：至少登记两个服务（后端、前端），command 用 argv 数组，不要用带 `&` 的组合命令，也不要后台化。先 `devpanel project validate --config <file> --json`，处理所有 error 级问题后再 `devpanel project register --config <file> --json`。
4. 核实注册没有启动任何东西：`devpanel status <id> --json` 中所有服务都是 `idle`。用同一份文件再注册一次，确认返回 `created:false`。
5. 启动前检查 8081 和前端端口是否已被别的进程占用；被占用就停下，报告给用户，不要杀进程。
6. `devpanel start <id> --json` 启动整个项目，等待操作结束。然后：
   - `devpanel status <id> --json`：记录每个服务的状态和运行 ID；
   - `devpanel logs <id> --service <sid> --tail 50`：确认能看到真实日志；
   - `devpanel stats <id> --json`：确认统计里包含真正干活的进程（java / next 的 node），而不只是 mvn / pnpm 外壳；记下 processCount 和 RSS。
   - 如果某个服务因为依赖（数据库、Redis、Java 版本等）启动失败，记录 DevPanel 显示的失败原因是否准确、可理解。这本身就是验收内容，不要绕过 DevPanel 改用别的方式启动。
7. 输出 `devpanel project rules <id>` 的规则文本给用户（不要写进 reg-radar 的文件）。
8. **暂停，请用户操作**：让用户运行 `devpanel open`，在面板里确认能看到同一个项目、同一批运行 ID、日志和 CPU / 内存，然后由用户在面板上点「停止」。等用户回复“已停止”后再继续。
9. 用户停止后：
   - `devpanel status <id> --json`：所有服务为 `stopped`，退出原因为 `user-stop`（或 `force-stop`），运行 ID 与第 6 步一致；
   - 用第 6 步记录的各运行 PID（通过 `GET /runs/:runId` 或 CLI 输出里的进程信息拿到 pid + 启动时间）核实这些进程全部退出，没有残留 java / node。**按 PID 和启动时间核对，不要按进程名搜索后下结论，也不要杀任何进程。**
10. 收尾：询问用户是否保留 reg-radar 的注册和 daemon。用户没有明确要求时，保留注册，daemon 保持运行。

## 汇报格式
1. 你为 reg-radar 登记的完整配置（敏感值打码），以及为什么这样选择命令、cwd 和 env。
2. 按第 4–9 步逐条给出结果：通过 / 未通过 / 被阻塞，附上关键命令和关键输出（敏感值打码）。
3. 对照产品文档 §16 的最后一条“完整验收”，给出明确结论：是否通过。
4. 发现的 DevPanel 问题（区分 bug、体验问题、文档问题），每条写明复现方式。
5. 现在系统里还剩下什么：daemon 是否在运行、reg-radar 是否仍注册、`~/.local/bin` 里装了哪些文件。
