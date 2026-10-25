# 接入新项目

目标：把项目的长期运行服务按它**真实的启动方式**注册进 DevPanel，并把 Agent 规则合并进项目的规则文件。全程不启动任何服务。配置文件的写法见 [config.md](config.md)。

## 1. 确认还没注册

`devpanel project list --json`，按 `root`（项目根目录的绝对路径）查找。已经注册过的，转到 config.md 的"更新配置"，不要再注册一份。

## 2. 调查真实启动方式

找出项目里**每一个**长期运行的服务（后端、前端开发服务器、worker……），每个服务都要弄清：

- **工作目录**和**完整 argv**：用项目自带的 wrapper（`./mvnw`、`./gradlew`），而不是全局的 `mvn`、`gradle`；前端用项目锁文件对应的包管理器（`pnpm-lock.yaml` → `pnpm`）。
- **工具版本**：项目要求的 JDK / Node 版本（`.java-version`、`.sdkmanrc`、`.nvmrc`、`engines`、`pom.xml` 的 `maven.compiler.release`），以及本机对应工具的绝对路径。daemon 的 PATH 不是你终端的 PATH，版本管理器（nvm、fnm、sdkman）装的工具常常找不到。
- **就绪依据（v0.4）**：从项目实际输出确认稳定的日志子串，或使用实际监听端口；登记 log / port 条件与等待上限。Spring Boot 可用 `Started … in` 的稳定子串，Vite 可用端口选项引用；不虚构就绪行。不支持 HTTP 探测或正则。
- **运行时配置**：profile、端口、监听地址、需要的环境变量。敏感值（token、密码、密钥）只记下变量名，值向用户要，或用 `{ "secret": true, "value": … }` 写入，不写进仓库里的任何文件。

依据项目自己的材料：`README`、`package.json` 的 `scripts`、`Makefile`、`.idea/runConfigurations`、`.vscode/launch.json`、`.env.example`、`application*.yml`。示例和惯例只作线索，以项目实际文件为准。

不属于服务的内容：一次性的构建 / 测试命令（v0.3 起可登记为快捷操作，见 [v0.3.md](v0.3.md)）；数据库、Redis 等依赖若跑在 Docker 里，DevPanel 不管容器，在汇报里列出，由用户自行启动。

完成标准：每个服务都有确定的 cwd、argv 和所需环境变量，说得出每一项来自哪个文件。有拿不准的（例如两个 profile 都像日常用的），问用户，不要猜。

## 3. 写配置

若 CLI help 包含 `--maven-project`，同时核对项目下实际的独立 Git 工作树根与 Maven 聚合工程根，将明确的相对路径写进 `repositories` / `mavenProjects`（见 config.md 的对应章节）。只登记源码工程，不登记历史构建副本、依赖目录；Maven 子模块按 POM 展示。确认没有目标时写空数组。不要因为公共根目录下有多个仓库就重复注册项目。

在临时目录（`mktemp -d`）里写 JSON 配置文件，不要放进仓库：注册后以 DevPanel 里保存的配置为准，仓库里的副本会和它分叉。把用户会调整的部分（profile、端口、监听地址、开关型参数）提炼成选项（params），写清楚 label、description 和 enum 的每个可选值的含义。写法和示例见 [config.md](config.md)。

## 4. 校验

```bash
devpanel project validate --config <file> --json
```

- `ok` 为 false：修正所有 `severity: "error"` 的问题后重新校验。
- 每条 warning 要么修正，要么在汇报里说明保留的原因。
- 检查 `services[].programResolved` 是不是你想要的那个程序（例如 `java` 解析到了正确的 JDK）。为 `null` 时，`pathUsed` 是 daemon 实际用的 PATH，按 config.md 的"PATH 与工具版本"处理。

## 5. 注册

```bash
devpanel project register --config <file> --json
```

- 退出码 0：`created: true` 是新注册；`created: false` 表示同一根目录已有完全相同的配置，返回的就是那个项目。
- 退出码 5 `CONFIG_CONFLICT`：该根目录已用不同配置注册。`error.details` 里有 `projectId`、`revision` 和 `diff`。把差异告诉用户，用户同意后按"更新配置"处理。

## 6. 合并 Agent 规则

```bash
devpanel project rules <project-id>
```

提醒在 Agent 自身环境配置中设置 `DEVPANEL_AGENT`，例如 `codex` / `claude-code`；不要把名称写成所有 Agent 共用的固定值。

把输出合并进项目已有的规则文件（`AGENTS.md`，Claude Code 项目还有 `CLAUDE.md`；两个都没有时新建 `AGENTS.md`）。作为单独一节追加；文件里已有 DevPanel 段时只替换那一段，其余内容保持不动。

## 7. 汇报

向用户报告：项目 ID；每个服务的 cwd、argv、解析到的程序路径；创建的非敏感选项及其当前值、就绪条件及依据；保留的 warning；需要用户自行准备的依赖或敏感值；规则合并到了哪个文件。

到此结束，不启动服务。用户要求启动时，再按 SKILL.md 的"日常操作"进行。
