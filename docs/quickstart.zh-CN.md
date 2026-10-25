# 第一个项目

[English](quickstart.md) | **简体中文**

[配置分享、导入预览、独立实例与 AI 工作标识](config-sharing.zh-CN.md)

目标：启动一次、查看同一份日志、亲手停止。DevPanel 只记录通过它启动的服务；注册配置不会执行命令。

## 安装与检查

下载对应架构的发行包（尚无 Release 时按 README 从源码构建），解压到长期位置。首次打开被拦截时，先尝试打开，再到系统设置 → 隐私与安全性 → 仍要打开。保留 Gatekeeper。

在 DevPanel → 安装 CLI 与登录启动中选择命令目录。已有文件先预览再确认替换，登录启动默认关闭。“接入第一个项目”指引可从菜单再次打开。

以默认安装目录为例，在终端检查：

```sh
export PATH="$HOME/.local/bin:$PATH"
command -v devpanel
devpanel --help
devpanel daemon status --json
```

使用你选择的实际目录。export 只影响当前终端，Agent 的 PATH 需要在其自身环境配置。管理服务未运行时，在 App 点“启动管理服务”。移动 App 后重新安装 CLI 链接。

## 运行随包示例

示例使用内置 Node 和系统分配的空闲端口。将 APP 改为实际位置：

```sh
APP="/Applications/DevPanel.app"
CLI="$APP/Contents/Resources/runtime/bin/devpanel"
NODE="$APP/Contents/Resources/runtime/node/bin/node"
DEMO_DIR="$(mktemp -d /tmp/devpanel-demo.XXXXXX)"
"$NODE" "$APP/Contents/Resources/demo/create-config.mjs" "$DEMO_DIR"
"$CLI" project validate --config "$DEMO_DIR/devpanel-demo.json" --json
"$CLI" project register --config "$DEMO_DIR/devpanel-demo.json" --json
```

以上只创建文件和登记配置。把注册结果的 project.id 填入下方，再启动：

```sh
PROJECT_ID="填入项目 ID"
"$CLI" start "$PROJECT_ID" --wait-ready --json
"$CLI" logs "$PROJECT_ID" --service web --digest
```

在 App 找到 DevPanel demo，确认已就绪、实际端口和同一个运行 ID。点击端口应看到 Hello from DevPanel。点击停止后核验并移除登记：

```sh
"$CLI" status "$PROJECT_ID" --json
"$CLI" project remove "$PROJECT_ID" --json
```

移除登记不删除源码；停止并移除后可自行删除示例目录。关闭窗口不会停止服务。

## 接入自己的项目

完整包附带 Contents/Resources/skills/devpanel；源码对应 skills/devpanel。按 Agent 的安装方式复制整个目录并保留 references。在 Agent 环境设置 DEVPANEL_AGENT=codex 或 claude-code，然后说：

> 按 DevPanel skill 把当前项目加入面板。核对实际启动脚本、工具路径、环境和就绪条件，把常改参数做成选项。先完成校验和注册并说明结果，暂不启动。

确认配置后再明确要求启动。核对来源、实际命令、工作目录、日志和就绪证据，并尝试从面板停止。保留项目规则，让新 Agent 会话继续使用同一个入口。

## 遇到问题

| 现象 | 下一步 |
| --- | --- |
| 终端能启动，面板找不到 java/pnpm | 运行 project validate，检查 programResolved/pathUsed，指定正确工具路径或项目 PATH |
| 运行中但未配置就绪 | 在编辑器补日志/端口条件；下次启动生效 |
| 就绪超时 | 进程可能仍在运行，检查本次日志，不循环重启 |
| AI 启动被拒 | 查看暂停/锁定原因，在面板决定是否允许 |
| 管理中断/状态未知 | 保留证据，先核验旧运行，避免重复启动 |

升级、回退、卸载见 README 和 release-v0.4.md。Gatekeeper、登录会话和通知需在目标 Mac 实际验证。
