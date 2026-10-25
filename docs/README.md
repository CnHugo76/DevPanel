# 文档导航

## 使用与贡献

- 项目首页：[English](../README.md) / [简体中文](../README.zh-CN.md)，包含功能、安装、CLI、数据与卸载。
- 快速开始：[English](quickstart.md) / [简体中文](quickstart.zh-CN.md)，使用随包独立示例。
- 配置分享、工作归属与独立实例：[English](config-sharing.md) / [简体中文](config-sharing.zh-CN.md)。
- 功能清单与 v0.4 优化建议：[English](features.md) / [简体中文](features.zh-CN.md)，区分原生界面、CLI、功能边界与发布前待办。
- [独立演示项目](../examples/demo/README.md)：使用临时数据体验注册、启动、就绪与日志。
- [Agent skill](../skills/devpanel/SKILL.md)：给 Codex / Claude Code 等 Agent 的操作说明。
- [贡献指南](../CONTRIBUTING.md)、[安全报告](../SECURITY.md)、[第三方声明](../THIRD_PARTY_NOTICES.md)。
- [macOS 开发与验收](../apps/mac/README.md)：SwiftPM、隔离 daemon、mock、快照参数。
- [GitHub 公开前检查](open-source.md)：许可证、提交历史、CI 与发布包。

## 当前设计与契约

- [产品 v0.4](product-design-v0.4.md) 覆盖与 v0.1–v0.3 冲突的条款；[v0.3](product-design-v0.3.md)、[v0.2](product-design-v0.2.md)、[v0.1](product-design-v0.1.md) 保留其余约定。
- [API 契约](../contract/api.md) 与 [TypeScript 类型](../packages/contract/src/index.ts) 共同定义接口；[契约提案](../contract/CHANGES.md) 记录变更。
- [后端工程说明](backend-design.md)、[界面 v3](ui-design-v3.md)、[界面 v2](ui-design-v2.md) 解释现有结构与交互。

## 版本与实现记录

- [四轮优化与验收](plan-four-rounds.md)：本轮工作区中的安装、排障、配置复用和 AI 并行工作改进，不代表已公开发行。
- [v0.4.1](release-v0.4.1.md)、[v0.4 打包与迁移](release-v0.4.md)。
- [v0.4 验收](plan-v0.4.md)、[v0.3 验收](plan-v0.3.md)、[v0.2 验收](plan-v0.2.md)。
- `prompts/` 保存历史开发任务；其中的环境版本、提交号和阶段指令是当时记录，不代替贡献指南。

历史记录中的 `.devpanel-dev/` 文件名指向开发者本地、被 Git 忽略的证据，不是随仓库分发的附件。公开截图位于 `docs/images/`。记录中的用户路径和项目名称已作示例化处理。
