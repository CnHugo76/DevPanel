你是 DevPanel 的后端开发者，继续 v0.2 的后端工作。仓库：/path/to/DevPanel。前端（原生 macOS 程序和 mock-daemon）由 Claude 并行开发，双方唯一的对接点仍是接口契约。

## 先读
1. `AGENTS.md`：目录所有权与契约变更流程（你只改 `packages/daemon/`、`packages/cli/`、`docs/backend-design.md`）。
2. `docs/product-design-v0.2.md`（本版范围），`docs/plan-v0.2.md` 中的 B1–B3。
3. `contract/CHANGES.md` 中已生效的 v1.1-A（选项）和 v1.1-B（端口），以及据此更新过的 `contract/api.md`、`packages/contract/src/index.ts`。以契约为准。
4. `docs/ui-design-v2.md` 了解界面如何使用这些接口（只读）。

## 要做的事
- **B1 选项**：`ProjectConfig.params` 的校验与持久化；启动时替换 `${key}`（命令 argv 与非敏感环境变量值，`$${` 为字面量）；shell 调用中的脚本参数按单引号转义；`RunDetail.params` 与替换后的 `RunDetail.command`（secret 片段为 `••••`）；`configChangedSinceStart` 按替换后的有效配置比较；设置者按 `X-DevPanel-Client` 记录；整份更新时保护 `setBy=user` 的值（`overrideUserValues`、`keptUserValues`）。
- **B2 路由与 CLI**：`POST /projects/:id/params`、`PATCH /projects/:id/params/:key`、`DELETE /projects/:id/params/:key?inline=`（含 secret 不得写回命令的限制）；`devpanel param list|set|remove`；`devpanel project rules` 输出补充选项相关规则。
- **B3 真实端口**：在资源采样中读取已核验受管进程的 TCP LISTEN 套接字，填入 `ServiceStats.listening`，按契约区分 `scope`，未读到为 `null`，确认没有为 `[]`。选择读取方式时说明成本（例如 `lsof` 的调用频率与耗时），只在有运行中服务时执行。

## 硬性要求
- 契约之外不新增字段或路由；发现契约问题按 `AGENTS.md` 写提案，不直接改契约。
- 替换永远在启动时进行，保存配置不触发启动或重启。
- 端口只来自受管进程，不扫描、不归属任何非受管进程；端口不作为停止或归属依据。
- 敏感值（secret 选项、敏感环境变量）不出现在任何响应、事件、`sys` 日志行或 CLI 输出中。
- 测试使用临时 `DEVPANEL_HOME`，不碰真实数据目录与已注册项目；保持 `--test-timeout` 与 `--test-force-exit`。

## 测试（至少覆盖）
- 占位符替换：argv 元素内替换、`$${` 字面量、数字 / 布尔格式化、项目级与服务级环境变量。
- 校验：`PARAM_UNKNOWN`、`PARAM_INVALID`（类型、choices、min/max）、`WARN_PARAM_UNUSED`。
- shell 转义：值含空格、单引号、`$`、`;` 时，在 `zsh -lc` 脚本中原样作为一个字面量。
- 覆盖保护：UI 改值后 CLI 整份更新，值被保留并出现在 `keptUserValues`；带 `overrideUserValues` 时被覆盖。
- `configChangedSinceStart`：只改某服务没引用的选项，该服务不被标记；改了被引用的选项，只标记引用方。
- 删除：未引用直接删；被引用且 `inline=false` → 409；`inline=true` 写回后服务可启动；secret 被命令引用时拒绝写回。
- 端口：fixture 分别监听 127.0.0.1 和 0.0.0.0；非受管的同端口监听进程不出现；停止后 `listening` 不再出现该服务。

## 完成后汇报
1. 改动的模块与 `docs/backend-design.md` 中新增的设计说明（尤其是端口读取方式与成本）。
2. 新增的 CLI 用法示例（真实可运行）。
3. 上面每一项测试的结果；全仓 `pnpm typecheck`、`pnpm test` 结果与耗时。
4. 契约提案（如有）与剩余限制。
