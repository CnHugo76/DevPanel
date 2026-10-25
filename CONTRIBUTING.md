# 参与贡献

欢迎提交中文或英文 Issue / Pull Request。新功能请先开 Issue 描述使用场景；项目聚焦本机服务管理、CLI 与 macOS 原生界面，当前范围见 [产品设计 v0.4](docs/product-design-v0.4.md)。

## 开始开发

需要 macOS 14+、Node 24+、pnpm 12 和支持 Swift 6 的 Xcode 工具链。仓库通过 `packageManager` 固定 pnpm 版本。克隆后在根目录执行：

```sh
pnpm install --frozen-lockfile
export DEVPANEL_HOME="$(mktemp -d /tmp/dp-dev.XXXXXX)"
export DEVPANEL_PORT=0
pnpm typecheck
pnpm test
pnpm build
swift test --package-path apps/mac
swift build -c release --package-path apps/mac
```

`DEVPANEL_HOME` 必须指向短路径的临时目录；macOS 的 Unix socket 路径上限为 103 字节。测试会创建隔离项目和进程，并检查清理结果。不要用开发版本连接日常数据、替换已安装的 App / CLI，或停止个人正在使用的 daemon。源码 CLI 入口为 `node packages/cli/src/main.ts`。

开发界面、mock 与手动验收见 [原生程序说明](apps/mac/README.md)；不依赖现有项目的入门示例见 [examples/demo](examples/demo/README.md)。

## 代码与接口

- TypeScript 使用 strict、ESM 和明确的 argv；Swift 使用 SwiftPM，原生界面基于 SwiftUI / AppKit。
- 接口以 [contract/api.md](contract/api.md) 与 [共享类型](packages/contract/src/index.ts) 为准。变更接口前，在 `contract/CHANGES.md` 提出语义、类型和客户端影响，接受后同步两处。
- 保存、导入、更新与校验配置都不能执行项目命令。发送进程信号前必须核对 PID 与启动时间；HTTP 只监听 `127.0.0.1`；敏感值不得出现在响应、日志或 CLI 输出中。
- 按改动运行相关检查。行为修复应附可复现步骤与必要的回归测试；文档和小型展示调整不要求新增测试。
- 不提交真实项目配置、凭据、日志、备份、构建产物或个人绝对路径。截图使用虚构数据，日志样本先脱敏。

## 提交 Pull Request

说明具体问题、改动后的行为，以及执行过的验证。界面变化附脱敏截图；尚未验证的系统交互请如实标明。保持一个 PR 围绕一个问题，避免顺带重排无关代码或修改锁文件。

公开 Issue 请提供 DevPanel / macOS 版本、CPU 架构、安装方式和最小复现。安全问题按 [SECURITY.md](SECURITY.md) 私下报告。
