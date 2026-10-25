# v0.4 本地发布包与手工稳定版迁移

本说明是供用户择时执行的步骤。开发与验收不执行真实环境迁移，不覆盖稳定版，不创建标签或 GitHub Release。项目采用根目录的 [MIT License](../LICENSE)，公开名称、版本标签与 GitHub 发布由维护者决定。

## 包的组成

`DevPanel.app/Contents/Resources/runtime/` 内含 Node 官方独立运行时（24.21.0）、daemon / CLI / 共享类型源码、生产依赖、原生采样辅助进程和 `bin/devpanel` / `devpaneld`。Node 24 原生剥离 TypeScript 类型；生产依赖保留包内许可证。采用独立运行时而非 Homebrew Node，避免引用安装机器的 Cellar / opt 动态库；也不需要让用户安装 Node、pnpm、Xcode 或源码仓库。

原生界面、嵌入的 Node 和采样器先后进行 ad-hoc 签名。发布脚本核验下载归档的官方 SHA-256，并为最终 ZIP 写出独立 SHA-256；不做开发者签名、公证或联网发布。构建产物与实测体积见 [v0.4 验收记录](plan-v0.4.md)。

开源整理后的发布脚本会把项目 `LICENSE` 与 `THIRD_PARTY_NOTICES.md` 放入 `Contents/Resources/`，并生成 `DevPanel-<version>-macos-<arm64|x64>.zip` 及同名 `.sha256`，避免两种架构的附件相互覆盖。

## 迁移前

1. 保留旧版 `~/.local/share/devpanel/stable`，确认当前 CLI 链接指向它；保留 App 副本便于回退。
2. 确认所有项目可停止，退出 DevPanel 界面。用当前稳定版 CLI 停止服务与 daemon；如安装过登录项，先卸载登录项并停止服务。
3. 确认 daemon 已停止后，复制备份 `~/Library/Application Support/DevPanel`。不要在 daemon 正在写入时备份，也不要把敏感配置放入公开仓库。

## 切换

1. 将解压的新版 App 放到长期位置；需替换 `/Applications/DevPanel.app` 时由用户亲自操作。
2. 按 README 的隐私与安全性步骤首次放行。新版沿用原数据目录，不自动启动项目。
3. 在引导中检查 CLI 的完整目标路径。旧 shim / 链接会显示现有内容；确认替换后指向新 App 内的 CLI。旧源码目录保留不动。
4. 原来有登录项的用户可重新选择“登录时启动管理服务”，使 ProgramArguments 指向新 App 内的运行时与 daemon；移动 App 后需要重新安装登录项。已有手动 daemon 时不会静默接管，应先正常停止再安装登录项。
5. 先核对项目和历史记录，再显式启动一个服务，检查日志、实际端口与停止操作。

只需先试用时，给新版设置独立的短路径 `DEVPANEL_HOME`，用停止后取得的数据副本验证。开发隔离场景保留旧启动器行为，需用副本里的内置 CLI 显式启动隔离 daemon；不要点击会寻找用户旧 CLI 的默认启动入口。旧版和新版可以并存，但不得同时写同一数据目录。

## 回退

先停止新版服务和 daemon、卸载新版登录项，退出新版界面。恢复备份数据，再恢复旧 App 与旧 CLI 入口；需要登录启动时用旧版重新安装。不要让旧版读取新版持续写入的数据，也不要对仍运行的旧身份直接发信号。备份的恢复与删除均由用户决定。

## 人工验证

干净 Mac 上仍需确认：无 Node / 源码时的 Gatekeeper 放行、CLI 目录选择与覆盖确认、登录启动及卸载、真实终端 PATH、系统通知授权与点击。这些交互不能仅凭本机隔离自动化通过就声称完成。
