# 快捷操作专属参数

在“编辑项目 → 快捷操作”中定义参数，点击该操作的运行按钮后，就能在当前窗口选择本次值。支持文本、布尔、数字、单选和多选，以及名称、说明、默认值、必填、敏感和数字范围。没有专属参数的操作保持一键执行。

“示例打包部署”的默认选择为前端＋后端，Runtime 未选，备份数据库开启。勾选服务、切换备份后点击“开始部署”；取消或 Esc 关闭表单，不创建运行。服务正在运行的提醒并入此表单。提交后，日志上方的“本次参数”显示实际选择；切换历史记录会读取对应快照，后续修改默认值或名称不改变旧记录。

配置结构与完整示例见 [参数配置](../skills/devpanel/references/config.md#操作专属参数)。`${action.key}` 引用当前操作参数，`${key}` 仍引用项目选项。多选以一个紧凑 JSON 字符串传给 argv 或环境变量，例如 `["backend","runtime"]`；脚本使用 JSON 解析。每次打开重新使用默认值，本次选择不修改项目选项、revision 或其他操作。

## CLI 和 API

```sh
devpanel action list PROJECT_ID --json
devpanel action run PROJECT_ID deploy-demo --params '{"services":["backend","runtime"],"backup":false}' --json
devpanel action run PROJECT_ID deploy-demo --params-file ./local-params.json --if-revision 7 --json
# --params-file - 从 stdin 读取，不能和 --params 同时使用。
```

敏感值优先用 stdin 或权限受限的本机文件传入。任务详情 `actionParams` 保存类型、当时名称、候选标签与选择；敏感值只返回 `{"secret":true}`。名称、说明和候选项是公开元数据，不能包含秘密。可分享配置会要求另外填写敏感默认值。

API 调用前确认 `GET /api/v1/daemon` 的 `capabilities` 包含 `action-params-v1`，再发送：

```http
POST /api/v1/projects/PROJECT_ID/actions/deploy-demo/runs
Content-Type: application/json
Authorization: Bearer <local daemon token>

{"ifRevision":7,"params":{"services":["backend","runtime"],"backup":false}}
```

省略 key 使用此操作默认值。字符串不会自动转成布尔或数字；必填文本不能空白，必填多选至少一项；false、0 是有效值。错误在执行前返回 `CONFIG_INVALID`（422），详情指向 `params.<key>`。配置过期返回 `REVISION_MISMATCH`（409），刷新复核后再提交。同操作已有运行时，相同有效值复用已有记录，不同值返回 `TASK_RUNNING`（409）。不自动重试结果不确定的部署。

旧 daemon 会忽略该路由的请求体，因此新版 CLI 和原生会先检查能力，缺失时要求升级。旧配置和无参数操作继续可用。

## 隔离体验

在仓库根目录执行以下命令，生成只打印参数的示例；它不会连接数据库或部署服务。

```sh
export DEVPANEL_HOME="$(mktemp -d /tmp/dp-ap.XXXXXX)"
export DEVPANEL_PORT=0
node examples/action-parameters/create-config.mjs "$DEVPANEL_HOME/project"
node packages/cli/src/main.ts daemon start --json
node packages/cli/src/main.ts project register --config "$DEVPANEL_HOME/project/devpanel-demo.json" --json
```

记下响应 `project.id`，在同一终端用源码 CLI 执行上面的 action run 示例，或运行开发 App（保持同一 DEVPANEL_HOME）体验表单。未点击开始前没有执行。结束后用源码 CLI `daemon stop --json` 停止该隔离 daemon。

真实部署需由项目脚本按 JSON 服务数组和布尔环境变量适配；仓库示例不修改真实项目或已安装稳定版。
