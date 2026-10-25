# 分享配置与独立实例

[English](config-sharing.md) | **简体中文**

面板保存的是当前有效配置。仓库文件采用显式交换：修改文件后导入，修改面板后导出，没有文件监听或双向自动同步。导入、导出和校验都不执行项目命令。

## 导出

```sh
devpanel project export <项目ID> --file devpanel.json --json
```

目标文件已存在时拒绝覆盖。导出包含 `devpanel.project` version 1、project 与 inputs，不包含 root、项目 ID、revision、运行历史或托管规则。

秘密值被移除并转为必需的本机输入；项目内 cwd 变为相对路径；命令、环境、参数中的绝对机器路径转为 path 输入。替换的单位是整个标量，例如 `--data=/old/path` 需要重新填写完整参数。绝对路径枚举的 choices 无法仅靠标量输入迁移，先改为 string 参数再导出。分享前仍需审阅普通文本中未标记或变形的秘密。

## 预览与保存

```sh
devpanel project import --config devpanel.json --root /你的项目 --json
```

缺少输入时退出 2，列出输入 ID 和目标位置。将值另存为 `devpanel.local.inputs.json`，格式是输入 ID 到 string/number/boolean 的 JSON 对象，类型必须匹配。将这个文件名加入 `.gitignore`，限制文件权限，不随共享配置提交；CLI 不回显输入值。

```sh
devpanel project import --config devpanel.json --root /你的项目 \
  --inputs devpanel.local.inputs.json --json
```

检查校验结果、变更字段和 `keptUserValues`。确认保存时加 `--apply`；更新已有目录还必须传 `--if-revision <预览显示的版本>`。版本冲突后重新预览和审阅，不自动重试。面板里由用户修改过的参数值仍受到保护。

原生程序提供同样的文件选择、目录选择、预览和显式保存流程。选择配置文件不代表允许执行其中的命令。共享文件最多 1 MiB，本机输入文件最多 64 KiB。

## 多目录与 AI 工作

另一 checkout 使用自己的实际目录导入。成对传 `--group "项目组" --instance "feature-a"` 可设置显示名称。同一真实 root 仍是同一项目；不同 root 保持独立的项目 ID、进程、日志、配置与托管规则。DevPanel 不创建或切换 worktree，也不自动改端口，启动两份前自行核对端口配置。原生程序可在项目编辑器填写实例组/名称，从顶部更多菜单筛选实例组；搜索框支持 group:组名、instance:实例名。

在 Agent 环境设置 `DEVPANEL_TASK=issue-42`、`DEVPANEL_TASK_LABEL="修复启动"`，或传 `--task`、`--task-label`。工作标识只是自报的关联信息，不是认证或授权。用 `devpanel activity <项目ID> --task issue-42 --json` 筛选；启动、停止和任务取消记录都保留工作来源。原生程序的项目“动态”页可直接输入工作 ID，也可点击一条动态的“仅看此工作”。

## 检索日志

`devpanel logs <项目ID> --run <运行ID> --search "错误文字" --json` 检索整个保留区，按普通文本匹配。继续分页时将 `scannedThroughSeq` 传入 `--after-seq`，并保持同一个 `throughSeq` 作为 `--through-seq`。已经淘汰的日志无法检索，新输出需重新搜索才会加入。

随包 demo 有可直接审阅的 `devpanel.json`。先按快速开始生成 server.mjs，将 node 输入设为本机可执行程序，再预览导入。
