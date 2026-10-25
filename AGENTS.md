# DevPanel 仓库规则（所有 Agent 必读）

DevPanel 是本地项目运行面板：管理服务（daemon）+ CLI + macOS 原生程序。产品范围以 `docs/product-design-v0.1.md`、`docs/product-design-v0.2.md`、`docs/product-design-v0.3.md`、`docs/product-design-v0.4.md` 为准（后者覆盖前者的冲突部分），范围外的功能一律不做。当前开发任务见 `prompts/codex-v0.4.md`，实现与验收记录写入 `docs/plan-v0.4.md`（v0.3 的记录见 `docs/plan-v0.3.md`）。

## 分工与目录所有权

两个 Agent 并行开发，**只改自己拥有的目录**：

| 目录 | 所有者 | 内容 |
| --- | --- | --- |
| `packages/daemon/` | 后端（Codex） | 管理服务 `devpaneld` |
| `packages/cli/` | 后端（Codex） | 命令行 `devpanel` |
| `docs/backend-design.md` | 后端（Codex） | 后端工程设计与实测记录 |
| `apps/mac/` | 前端（Claude） | SwiftUI 原生程序（v0.2 起的主界面） |
| `apps/ui/` | 前端（Claude） | React Web UI（原生程序齐全前保留，之后退役） |
| `tools/mock-daemon/` | 前端（Claude） | 按契约模拟的 daemon，供 UI 独立开发 |
| `docs/ui-design*.md`、`docs/ui-mockup*.html` | 前端（Claude） | 界面设计 |
| `contract/`、`packages/contract/` | **共享，冻结** | 接口契约，只能按下面流程改 |
| 根目录 `package.json`、`pnpm-workspace.yaml`、`tsconfig.base.json` | 共享 | 只允许追加脚本，不改已有内容 |

不要读取另一方的实现来“猜”接口，接口只看契约。

## 契约变更

1. 契约 = `contract/api.md`（语义）+ `packages/contract/src/index.ts`（类型）。两者必须一致。
2. 实现中发现契约不够用或有错：**不要直接改契约**。在 `contract/CHANGES.md` 的“待决提案”里写一条提案（动机、具体差异、对另一方的影响），然后在给用户的汇报里明确列出，由用户转达并确认。
3. 提案被接受后，由提出方同时修改 `api.md` 和 `index.ts`，把提案移到“已生效”。
4. 在提案确认前，按现有契约实现；确实无法实现的部分记为限制。

## 技术约定

- Node ≥ 24，pnpm workspace，TypeScript strict，ESM。
- 各包只在自己的 `package.json` 里加依赖，尽量少依赖；不引入数据库服务、消息队列、容器、大型后端框架。
- 避免两个 Agent 同时运行 `pnpm install`；若 `pnpm-lock.yaml` 冲突，重新执行一次 `pnpm install` 即可，不要手改 lock 文件。
- 每个包提供 `typecheck`、`test`（如有）、`build` 脚本；根目录 `pnpm typecheck` / `pnpm test` 必须能通过。
- 测试与开发运行一律设置 `DEVPANEL_HOME` 到临时目录或 `.devpanel-dev/`，**绝不**读写真实的 `~/Library/Application Support/DevPanel`，也不要注册真实项目。
- **用户的稳定版**：用户日常使用的是 `~/.local/share/devpanel/stable`（当前为 git 标签 `v0.3.1`；回滚用的旧版本在 `~/.local/share/devpanel/stable-v0.3.0`、`stable-v0.2.0`）、`~/.local/bin/devpanel` / `devpaneld`（指向稳定版）、`/Applications/DevPanel.app`，以及用真实数据目录运行的 daemon。开发时**不要**调用 `~/.local/bin` 中的命令（直接用 `node packages/cli/src/main.ts`），**不要**运行不带 `--bin-dir` 的 `setup:cli`，不要修改稳定版目录、`/Applications/DevPanel.app`，不要停止或重启用户的 daemon。升级稳定版只由用户决定。

## 安全底线

- 只对能核验属于本次运行的进程（pid + 启动时间）发信号；禁止 `killall`、按名称或端口杀进程。
- HTTP 只监听 127.0.0.1；敏感环境变量值不得出现在任何响应、日志、CLI 输出中。
- 导入配置不等于执行授权：注册、更新、校验都不执行项目命令。

## v0.3 分工（2026-10-21 起）

经用户确认：v0.3 的前后端实现（含 `apps/mac/`、`tools/mock-daemon/`）全部由 Codex 负责，Claude 负责产品 / 界面设计、契约提案、给 Codex 的任务说明与 review。任务说明见 `prompts/codex-v0.3.md`。契约仍按上面的流程变更：实现中发现契约问题，写进 `contract/CHANGES.md` 的“待决提案”，由用户确认后再改。上表中的目录所有权在本阶段按此执行。

## v0.4 分工（2026-10-22 起）

经用户确认：v0.4 沿用 v0.3 的分工。Codex 实现前后端、mock、原生程序与发布包，并按任务说明更新 `skills/devpanel/`；Claude 负责设计、契约与 review。任务说明见 `prompts/codex-v0.4.md`，契约 v1.3-A ~ v1.3-D 已生效。v0.4 是开源项目：只在本地产出发布包，不做签名、公证或包管理器分发，不推送、不创建 GitHub Release。
