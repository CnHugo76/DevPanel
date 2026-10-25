# GitHub 开源准备与发布记录

2026-10-25 完成本地整理后，维护者明确要求创建公开 GitHub 仓库并推送当前源码。仓库为 [CnHugo76/DevPanel](https://github.com/CnHugo76/DevPanel)，采用 MIT；首次推送仅包含当前源码的全新 `main` 历史，不上传旧开发提交与标签，也不创建 GitHub Release。

## 已准备

- README 的功能入口、独立 demo、源码构建与文档导航。
- 贡献指南、安全报告流程、问题反馈与功能建议模板、PR 模板。
- GitHub Actions：macOS 上的 TypeScript 类型检查、测试与构建，以及 Swift 测试与 release 构建。工作流只读仓库，无自动发布步骤；首次完成的远程运行结果见文末。
- `.gitignore` 排除本地环境文件、密钥文件、日志、开发数据与构建产物，保留脱敏 `.env.example`。
- 文档中的个人绝对路径已替换为示例路径；旧测试样本、路径格式化注释与用例中的用户名统一使用 demo。旧安装记录中的实际项目名称和备份时间已示例化。历史验收记录保留其结果，不随仓库分发本地证据。
- 发布脚本随 App 复制项目许可证与第三方声明；Node 和生产依赖自带的许可文件保留在内置运行时中。`@nodable/entities` 的 npm 包未附完整文本，已按对应发布提交补入第三方声明。ZIP 与校验文件均标注 macOS 和 CPU 架构。
- 已由维护者选定 MIT，根目录 `LICENSE` 使用仓库作者名 Hugo 署名。

## 公开历史与后续设置

1. **提交历史**：旧开发历史含工作邮箱、本机路径和真实项目安装记录。为使当前工作目录继续用于开发，本地 `main` 从整理后的源码建立无父提交的公开历史，旧历史与当前源码快照完整保存在仅本地的备份分支。首次推送只指定 `main:main`，本仓库配置禁用自动跟随标签，提交身份采用 GitHub noreply 邮箱。以后不要使用 `git push --all` / `--tags` 或镜像推送上传本地旧对象。
2. **仓库身份**：通过已连接的 GitHub 账号及浏览器确认维护者为 `CnHugo76`，仓库名为 `DevPanel`；`origin` 使用 SSH，本地 `main` 跟踪 `origin/main`。已有同名商业产品，命名调研见 [市场调研](market-research-2026-10-21.md#名称需要在推广前处理)。
3. **GitHub 设置**：Issues 随仓库启用。私密漏洞报告、Secret scanning / Push protection（账户支持时）与 `main` 所需检查可在首次 CI 验证后配置。

## 发布包

当前公开源码包含本地 v0.4.1 标签之后的界面与日志改进；旧标签不代表当前公开源码。首次公开发行时应选择新版本，记录所包含的改动，并从明确的提交重新构建，不把旧 ZIP 当成本轮整理后的产物。版本核对、功能清单与建议见 [v0.4 功能清单](features.zh-CN.md)。

发布前在隔离环境依次运行贡献指南中的检查，然后：

```sh
export DEVPANEL_HOME="$(mktemp -d /tmp/dp-release.XXXXXX)"
export DEVPANEL_PORT=0
# 将 VERSION 替换成准备发行的新版本；这里只展示预览版本。
VERSION=0.4.2-dev pnpm release:local
node scripts/release-smoke.mjs
```

产物默认在 `.devpanel-dev/codex/v04/release/`，ZIP 名称为 `DevPanel-<version>-macos-<arm64|x64>.zip`。确认包内项目许可证、第三方声明、Node / 依赖许可证、签名验证和 SHA-256。干净 Mac 的 Gatekeeper、PATH、登录启动和通知仍需人工验证。打包和 smoke 不等于已经验证全部安装交互。

## 本地检查的范围

2026-10-25 对整理前的 423 个受版本控制文件及全部本地 refs 中的 1,147 个文本 blob，检查了常见私钥、GitHub / AWS / Google / Slack / Stripe / OpenAI 令牌格式和含密码的 URL，未发现格式命中；这不涵盖未知格式、二进制内容或截图像素。公开首页截图已人工查看，内容为 mock 演示数据。

`.devpanel-dev/` 与构建目录未被版本控制。冻结的契约提案、旧设计示例和提交消息仍应由维护者审阅其公开范围。完整原始扫描结果仅保存在被忽略的 `.devpanel-dev/open-source/`，不包含秘密值。

## 本轮验证结果

- `pnpm typecheck`、`pnpm test`、`pnpm build` 通过；TypeScript / Web 共 245 项测试通过（daemon 109、CLI 29、mock 55、Web 52），daemon 的 106 个测试进程身份审计无残留。
- Swift 320 项测试 / 54 suites 通过；原生 release 构建、ad-hoc 签名核验和完整运行时打包通过。
- 独立 demo 的注册、就绪、HTTP 响应、日志摘要、动态及清理流程通过。
- `0.4.2-dev` Apple Silicon 预览包通过独立目录、无外部 Node 的 smoke；包内项目许可证与第三方声明和源码一致。该版本只用于本轮预览，没有创建标签或正式发行。
- 对包括未跟踪新增内容在内的 440 个当前文件再次检查常见密钥格式，无命中。文档入口链接、GitHub YAML、脚本语法及 `git diff --check` 通过。

全量测试最初暴露 Git 超时夹具的启动握手不稳定。现将夹具保存为显式 `.mjs`，通过 shell `exec` 启动，给身份握手独立的有界等待；产品的 10 秒查询超时及进程身份核验断言保留。首轮两个采样器时序失败在隔离重跑及最终全量中通过，未修改采样器代码。Intel 打包及干净 Mac 的系统交互仍待对应环境验证。

2026-10-25 首次完成的公开 [GitHub Actions](https://github.com/CnHugo76/DevPanel/actions/runs/40162240195)（提交 `2fc5902`）中，TypeScript 类型检查、测试与 workspace 构建通过；Swift 测试步骤在编译通知接口时失败：`AppNotifications.swift:31` 的 `UNNotificationSettings` 不能跨隔离域，原生 release 构建因此跳过。在该次核对时远程 CI 尚未通过，兼容修复和重验列为打公开标签前的 P0，不能用本地通过结果代替。

随后按维护者要求修复：在系统通知回调中读取设置，只将授权状态枚举传回主线程，避免传递整个非 Sendable 设置对象；CI 增加 Xcode / Swift 版本输出，保留原有类型检查、测试与 release 构建步骤。该问题在 GitHub Xcode 16.4 环境出现，本机 Xcode 27.1 的结果不能替代旧工具链验证；修复后的远程结果见 [CI 运行记录](https://github.com/CnHugo76/DevPanel/actions/workflows/ci.yml)。

另生成 `.devpanel-dev/open-source/DevPanel-source-preview.zip`：包含本轮已验证的当前源码、MIT 许可与文档，不包含 `.git`、依赖、构建产物或本地运行数据。它可作为首次公开的源码起点，原仓库及其全部历史保留在本地。
