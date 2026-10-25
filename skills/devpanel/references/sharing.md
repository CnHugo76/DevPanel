# 复用配置与并行工作

先检查 `devpanel --help` 包含 `project export/import`、`--task`；旧版不传这些参数。

## 分享配置

1. 读取目标项目，运行 `devpanel project export <id> --file <新文件> --json`。导出默认拒绝覆盖。仓库文件推荐 `devpanel.json`。
2. 审阅文件：secret 的 value 已移除；root 内 cwd 已相对化；本机绝对命令、环境、参数值变为 inputs。未标记或变形的秘密需人工识别。路径枚举 choices 无法通过标量输入迁移，先改为 string 参数。
3. 本机输入另存 `devpanel.local.inputs.json` 并加入 `.gitignore`。它是 input ID 到标量值的对象，不复制到共享文档、日志或回复中。路径替换作用于整个标量，命令参数中的路径需填写完整参数。
4. `devpanel project import --config devpanel.json --root <本机目录> [--inputs devpanel.local.inputs.json] --json` 只预览。缺输入时退出 2 并列 requiredInputs/missingInputs；齐全后校验，检查 changes、validation 和 keptUserValues。
5. 用户已授权保存配置时，加 `--apply`；更新已有根目录还须传预览的 `--if-revision`。冲突后重新读取并审阅，不循环强行覆盖。导入完成到此为止，只有另外获得启动授权才启动。

面板保存的是当前有效配置。仓库文件修改需显式导入；面板修改需显式导出。没有后台监听或双向同步。共享文件最多 1 MiB，本机输入文件最多 64 KiB。

## 工作归属

为当前工作选择稳定且不含秘密的 ID，设置 `DEVPANEL_TASK`（1–64 字符，字母/数字开头，后续可含点、下划线、连字符）与可选 `DEVPANEL_TASK_LABEL`（1–120 字符单行名称）。命令参数 `--task` / `--task-label` 优先；工作名称需要 ID。同一工作后续启停和操作继续使用该 ID，任务结束后移除该环境上下文。

`devpanel activity <id> --task <工作ID> --json` 是筛选，只返回对应动态；工作标识不改变暂停、锁定或进程所有权，不表示认证。

## 独立目录

同一项目的另一 checkout 必须用实际 root 注册为独立项目。导入可成对传 `--group <组名> --instance <实例名>`；两个字段各 1–80 字符，只作显示。启动前核对 projectId、root、服务和端口参数。DevPanel 不创建或切换 worktree，不自动分配端口，不接管外部进程；每个目录的规则、运行和日志独立。
