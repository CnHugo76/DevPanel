# 项目配置

`register`、`validate`、`update` 的 `--config` 都接受同一种 JSON 文件（`ProjectConfig`）。保存和校验都不执行任何命令。

## 结构

```jsonc
{
  "schemaVersion": 1,
  "name": "显示名称",
  "root": "/项目根目录的绝对路径",
  "env": { },              // 可选，项目级环境变量，所有服务共用
  "params": [ ],           // 可选，选项，见下文
  "services": [            // 至少一个；数组顺序就是项目级启动顺序
    {
      "id": "backend",     // /^[a-z][a-z0-9-]{0,31}$/，项目内唯一，注册后不要改
      "name": "后端",
      "cwd": ".",          // 相对 root，或绝对路径
      "command": ["./mvnw", "spring-boot:run"],  // argv 数组，不是 shell 字符串
      "env": { },          // 可选，覆盖项目级同名变量
      "ready": { "check": { "kind": "log", "contains": ["Started"] }, "timeoutSec": 120 },
      "stopTimeoutSec": 10 // 可选，优雅停止等待秒数，1–300，默认 10
    }
  ]
}
```

项目级 `start` 按数组顺序依次拉起各服务，不等前一个就绪，也不做健康检查。

## 命令写法

- `command` 是 argv：每个参数一个元素，`command[0]` 是程序名（在有效 PATH 中查找）或路径。
- 服务必须**前台运行**：去掉 `&`、`nohup`、`-d` / `--detach`、`daemon`/`start` 这类会让进程脱离的写法，DevPanel 自己负责托管（校验会给出 `WARN_BACKGROUND_COMMAND`）。
- 确实需要 shell（例如先 `source` 一个脚本）时写成 `["zsh", "-lc", "source ./env.sh && exec pnpm dev"]`，用 `exec` 让真正的服务进程接替 shell。用 `&&`、`;`、`|` 串起几个长期进程会得到 `WARN_SHELL_COMPOUND`，应拆成多个服务。

## PATH 与工具版本

daemon 的 PATH 来自 daemon 自身，不是你终端的 PATH；校验结果的 `pathUsed` 给出实际值。程序找不到（`COMMAND_NOT_FOUND`）或解析到错误版本时，任选其一：

- `command[0]` 写绝对路径；
- 在 `env` 里设置 `PATH`。它整体替换原值，记得带上 `/usr/bin:/bin:/usr/sbin:/sbin`；
- Java 项目在 `env` 里设置 `JAVA_HOME`，指向项目要求的 JDK。

## 环境变量与敏感值

- 普通值写字符串：`"SPRING_PROFILES_ACTIVE": "local"`。
- 敏感值写成 `{ "secret": true, "value": "…" }`。DevPanel 不会在任何输出里返回它，`project show` 里只显示 `{ "secret": true }`。
- 更新时保留已存的敏感值，写 `{ "secret": true }`（不带 `value`）即可；`project show` 输出的就是这种形式，可以直接沿用。
- 敏感值从用户处取得；配置文件放在临时目录，用完删除。

## 选项（params）

选项是项目里**会被人调整的那部分配置**，面板里按类型显示为控件，人改值，不必读命令。

```jsonc
{
  "key": "profile",        // /^[a-zA-Z][a-zA-Z0-9_]{0,31}$/
  "label": "Spring profile",
  "type": "enum",          // string | number | boolean | enum
  "value": "local",
  "description": "后端加载 application-<profile>.yml",
  "choices": [             // 仅 enum，至少一个
    { "value": "local", "label": "本地", "description": "连本机数据库" },
    { "value": "dev", "label": "开发环境", "description": "连共享开发库" }
  ]
  // number 可加 "min" / "max"；敏感值加 "secret": true
}
```

- 在服务/快捷操作的 `command` 元素、非敏感环境变量值、以及 `ready.check.port` 中写 `${key}` 引用，启动时按当时保存的值替换。一个 argv 元素替换后仍是一个元素。
- 形如 `${HOME}` 的合法 key 若没有定义，会报 `PARAM_UNKNOWN`；要写字面量 `${`，写成 `$${`。
- 适合做选项的：profile、端口、监听地址、开关型参数、常切换的连接目标。命令里固定不变的部分保持原样。
- description 写给人看：这个值影响什么，每个可选值意味着什么。
- 定义了却没被引用会得到 `WARN_PARAM_UNUSED`。

## 示例

Spring Boot 后端（项目根有 `mvnw`）+ Vite 前端：

```json
{
  "schemaVersion": 1,
  "name": "shop",
  "root": "/Users/me/code/shop",
  "env": {
    "JAVA_HOME": "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home"
  },
  "params": [
    {
      "key": "profile", "label": "Spring profile", "type": "enum", "value": "local",
      "description": "后端加载 application-<profile>.yml",
      "choices": [
        { "value": "local", "label": "本地", "description": "连本机 MySQL" },
        { "value": "dev", "label": "开发环境", "description": "连共享开发库，需 VPN" }
      ]
    },
    {
      "key": "backendPort", "label": "后端端口", "type": "number", "value": 8080,
      "min": 1024, "max": 65535, "description": "前端代理也指向这个端口"
    },
    {
      "key": "frontendPort", "label": "前端端口", "type": "number", "value": 5173,
      "min": 1024, "max": 65535, "description": "Vite 实际监听端口"
    },
    {
      "key": "frontendHost", "label": "前端监听地址", "type": "enum", "value": "127.0.0.1",
      "description": "前端开发服务器监听的地址",
      "choices": [
        { "value": "127.0.0.1", "label": "仅本机" },
        { "value": "0.0.0.0", "label": "局域网", "description": "手机可通过本机 IP 访问" }
      ]
    }
  ],
  "services": [
    {
      "id": "backend", "name": "后端", "cwd": ".",
      "command": ["./mvnw", "-pl", "backend", "spring-boot:run",
                  "-Dspring-boot.run.profiles=${profile}",
                  "-Dspring-boot.run.arguments=--server.port=${backendPort}"],
      "env": { "DB_PASSWORD": { "secret": true, "value": "（向用户要）" } },
      "ready": { "check": { "kind": "log", "contains": ["Started"] }, "timeoutSec": 120 },
      "stopTimeoutSec": 20
    },
    {
      "id": "frontend", "name": "前端", "cwd": "frontend",
      "command": ["pnpm", "dev", "--host", "${frontendHost}", "--port", "${frontendPort}", "--strictPort"],
      "env": {
        "PATH": "/Users/me/.local/share/fnm/aliases/default/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "VITE_API_PORT": "${backendPort}"
      },
      "ready": { "check": { "kind": "port", "port": "${frontendPort}" }, "timeoutSec": 30 }
    }
  ]
}
```

示例中的路径、版本和参数只说明字段用法，按实际项目调整。

## 就绪条件（v0.4）

服务的 `ready` 可省略；省略时报告“未配置”，退出码仍可为 0。

- 日志：`{"check":{"kind":"log","contains":["Started "]},"timeoutSec":120}`。1–5 个非空子串，每项 1–200 字符，业务日志命中任一子串即就绪；只做子串匹配，不支持正则。
- 端口：`{"check":{"kind":"port","port":"${frontendPort}"},"timeoutSec":30}`。可填 1–65535 整数，或完整的 `${key}` 引用 number 选项；省略 port 表示任意实际 LISTEN 端口。secret 选项引用被拒绝。
- timeoutSec 为 1–900 秒，超时只标记、不停止进程。启动时快照条件与端口值；修改后下次启动生效。只修改 ready 不触发 configChangedSinceStart。
- `param list` 的 usedBy.where 可为 ready。移除被引用选项时需先改条件；明确要求 `param remove … --inline` 时，会把 ready.port 的当前值写回为 number。

托管规则不在 ProjectConfig 中；CLI 的 `policy <project-id> --json` 只读，保存规则与解除暂停由界面完成。

## 更新配置

更新是**整份替换**：请求里没有出现的已有服务视为删除。

1. `devpanel project show <project-id> --json`，记下 `revision`，把 `config` 对象另存为临时配置文件。
2. 在这份文件上修改。要保留的服务、选项、敏感值原样留着。
3. `devpanel project validate --config <file> --json`，处理问题同 onboarding.md 第 4 步。
4. `devpanel project update <project-id> --config <file> --if-revision <revision> --json`。
5. 响应里有 `keptUserValues` 时，这些选项是用户在面板里改过的值，已被保留，没有采用你文件里的值。告诉用户；用户要求时再用 `param set` 改。
6. 运行中的服务不受影响，下次启动才生效（见 SKILL.md"修改已注册项目"）。

退出码 5 时按 `error.code` 处理：

- `REVISION_MISMATCH`：配置在你读取后被改过（通常是用户在面板里改的）。回到第 1 步重新读取，把你的修改重新应用到新配置上，不要用旧文件覆盖。
- `PROJECT_RUNNING`：你删掉了一个正在运行的服务。问用户是否先停止它。
- `CONFIG_CONFLICT`（注册时）：见 onboarding.md 第 5 步。

## 移除项目

`devpanel project remove <project-id> --json` 只删除 DevPanel 里的配置、运行记录和日志，不碰项目文件。有服务在运行时返回 `PROJECT_RUNNING`；只在用户要求移除时使用。

## Git 仓库与 Maven 工程（v0.4.1）

确认 `devpanel --help` 包含 `--maven-project` 后可用：

```jsonc
"repositories": [
  { "id": "frontend", "name": "前端", "path": "frontend" },
  { "id": "backend", "name": "后端", "path": "backend" }
],
"mavenProjects": [
  { "id": "server", "name": "服务端构建", "path": "backend/server", "executable": "auto" }
]
```

AI 核对实际文件后明确登记，不依赖面板猜目录。Git path 必须直接有 `.git`（包括 worktree 文件）；Maven path 是含 `pom.xml` 的工程根，聚合 POM 的模块无需重复登记。路径相对项目 root，可为 `.`，真实路径不能越界；不含 `..` 或选项占位符。每类 ID 与真实目录唯一，最多 32 项。

省略字段保留旧根目录行为；`[]` 明确表示没有该类目标。公共根目录下的独立仓库可以挂在同一个 DevPanel 项目，保留原服务和选项。Maven executable 按工程设置 auto / wrapper / mvn，auto 优先工程目录的可执行 mvnw。

补齐已有项目时，只修改这两个数组，按上文更新流程保留敏感值与 `setBy: user` 的选项，使用最新 revision。校验和保存不执行 Git 写操作、Maven 构建或服务命令。完成后只读查询目标；构建、服务启停仍需对应任务授权。面板选择目标后分别展示，Git 写操作只能由界面发起。
