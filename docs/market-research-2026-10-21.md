# DevPanel 开源市场调研

调研日期：2026 年 10 月 21 日。

**DevPanel 值得开源验证，但不宜以“市场空白”或“已经成熟的商业产品”发布。** 本地服务管理有长期存在的替代品，面向 AI agent 的 GUI、CLI 和常驻进程管理也已有直接竞品。当前更合适的目标是：让一小批开发者真正安装并持续使用，验证 macOS 原生体验、项目配置和人机共用运行入口能否形成偏好。付费需求尚未得到证明。

## 市场里已经有哪些选择

下表依据产品官网及官方源码仓库，说明公开提供或宣称的能力；没有安装实测这些竞品，因此不作稳定性、性能和安全质量排名。

| 产品 | 已有能力及许可 | 对 DevPanel 的含义 |
| --- | --- | --- |
| [Pier](https://trypier.app/) | macOS 原生 App、CLI、MCP 共用 runtime；后台 supervisor、日志、worktree 端口调整，还管理 Lima VM 和容器。官网仍显示 beta 入口及 v0.0.1。 | 最直接的原生界面竞品；“人和 agent 管同一组进程”已经有人明确宣传。其功能声明不能直接视作成熟交付证明。 |
| [lpm](https://lpm.cx/) | 免费、MIT；桌面项目和 agent 工作区。[Agent 文档](https://lpm.cx/connect-ai-agents)明确有服务启停、日志、等待端口、JSON CLI、项目配置 skill 和 worktree。 | 连“CLI + skill，无需另装 MCP”也不是独有差异；DevPanel 应突出更聚焦的服务面板体验。 |
| [Candle](https://github.com/facetlayer/candle) | MIT；面向本地开发、worktree 和 agent 的 CLI；按项目管理后台进程、防重复启动、读取日志、探测实际监听端口，另有可选 MCP。 | “AI 不重复起服务”和“识别实际端口”已有轻量替代；原生界面与可编辑参数需要产生额外价值。 |
| [DevWebUI](https://devwebui.lunarwerx.com/) | MIT；GUI 和 MCP 控制同一 daemon，提供状态、CPU、内存、日志、端口冲突提示；有多平台下载。 | 与 DevPanel 的基础架构和价值主张高度重叠，不能仅靠“共享 daemon”区分。 |
| [PortBay](https://github.com/portbay-app/portbay) | AGPL-3.0；本地无容器开发环境，项目运行、HTTPS、DNS、数据库及 MCP。[文档](https://docs.portbay.app/)描述 GUI 与 CLI 共用 registry。 | 环境管理和 agent 控制正在合流；不建议为追齐而扩张成数据库、代理和容器平台。 |
| [Quay](https://github.com/manustays/quay) / [portbar](https://portbar.app/) | 两者均为 MIT。Quay 用 Tauri 做 macOS 菜单栏服务与 agent 监控；portbar 按仓库和 worktree 展示端口、资源，并运行项目脚本。 | 轻量、免费、Mac 菜单栏也是拥挤方向。“能看到端口和 CPU”不足以单独吸引迁移。 |
| [Process Compose](https://github.com/F1bonacc1/process-compose) | 非容器进程编排，YAML、依赖顺序、健康检查、重启策略、TUI、CLI、REST；当前 README 已列 MCP server。 | 后端编排能力的强替代，不应描述为“只能命令行、不支持 AI”。 |
| [dekit](https://github.com/pvolok/dekit) | MIT；原作者的 mprocs URL 当前重定向至 dekit，README 明确它是 mprocs 下一版；支持后台任务、依赖、TUI 及供人和 agent 使用的 CLI。 | 不宜用旧版 mprocs 的前台命令集合印象比较当前竞争环境。 |

传统替代品仍重要：[Overmind](https://github.com/DarthSim/overmind) 通过 Procfile 和 tmux 管多进程，也能 daemonize、单服务重启；[PM2](https://pm2.keymetrics.io/) 本来就有 daemon、日志和监控，其官网现在还列出连接 PM2.io 监控的 MCP。开发者可能继续使用已有终端、IDE 与脚本，而不是安装任何新面板。

相邻市场中，[ServBay](https://www.servbay.com/)覆盖语言运行时、数据库和本地开发环境，并已宣传 MCP；[OrbStack](https://orbstack.dev/)聚焦容器和 Linux。它们证明开发环境桌面工具有成熟的产品形态，但不等同于本项目的直接需求。[DevHub](https://github.com/jaywcjlove/DevHub)主要是离线开发工具合集，不应因为同为 Mac 开发者工具就算核心进程管理竞品。另发现 Grove 脚本运行器线索，但其官网本次无法读取，不据此采用功能或价格结论。

## 价格信号意味着什么

| 官方页面 | 调研时公开价格 | 可以支持的判断 |
| --- | --- | --- |
| [Pier](https://trypier.app/) | 一次性 99 美元，可选每年 49 美元续费 | 有直接竞品尝试售卖原生进程与 agent 管理体验；仍属 beta 页面，不能推导销量。 |
| [ServBay](https://www.servbay.com/pricing) | 免费档；月付 Pro 9.9 美元，Team 39.9 美元 | 更广泛的环境管理产品有分层定价。 |
| [OrbStack](https://orbstack.dev/pricing) | 个人非商业免费；商业 Pro 年付 96 美元，折合每用户每月 8 美元 | 开发者基础设施体验有付费路径，适用范围与 DevPanel 不同。 |

同时，lpm、Candle、Quay、portbar、DevWebUI 都有免费开源替代。**标价代表卖方的尝试，不代表开发者愿意为 DevPanel 付费。** 本次没有可验证的该细分市场活跃用户、收入或付费转化数据，不估算市场规模。GitHub star、下载次数和官方功能文案也不能替代留存证据。

## DevPanel 应怎样定位

建议先验证这个具体人群：在 Mac 上并行维护多个本地项目、经常让 Claude Code 或 Codex 修改并启动服务、希望自己能随时看到和接管运行状态的开发者。Java/Maven 与前端混合项目可作为第二个测试群体，不能因 v0.3 有 Maven 计划就认定存在市场缺口。

对外可以表述为：**“macOS 上供开发者和 AI 共用的本地项目运行面板：统一启动服务、查看日志与实际端口，并把项目参数留在可检查的配置中。”** 这是一句清晰定位，不是独占能力声明。

目前最值得验证的是几个能力结合后的体验：SwiftUI 原生界面是否更顺手；AI 配置与人工改参数是否衔接自然；日常启停和异常恢复是否可靠；多语言项目是否比现有脚本更省事。开源有助于用户检查命令执行、进程归属和配置处理，但不能仅凭源码公开就宣称安全。

其中，[v0.2 的可编辑参数](product-design-v0.2.md)值得作为演示重点：AI 把 profile、端口等提炼成控件，人修改后，AI 后续更新默认保留人的值；保存只影响下次启动。这比笼统说“支持 AI”更具体。[v0.3 的 Maven 视图](product-design-v0.3.md)则适合用 Java 后端与前端混合项目验证，观察用户能否减少仅为运行、构建而打开 IDEA 的次数。二者是值得测试的差异方向，尚不能宣称竞品完全没有或用户必然需要。

不建议把路线扩大为新 IDE、agent 编排器或本地云平台。现有竞品已经覆盖很多这些方向，而 DevPanel 的产品范围有明确边界。Maven 快捷任务和基础 Git 仍在 v0.3 开发中，应标明状态，开源也不必等待它们全部完成。

## 名称需要在推广前处理

[DevPanel 云平台](https://www.devpanel.com/platform/)已经使用同名品牌，提供运行在用户 AWS、Azure、DigitalOcean 账户中的开发与部署平台。虽然产品用途不同，却都属于开发工具领域，搜索、文档和口头推荐容易混淆。

建议公开推广前选择更有辨识度的名字，并检查 GitHub、域名、包名与相关商标。当前只能确认存在同名和传播风险，不能由网页搜索判断商标权利或认定侵权。本报告不执行改名。

## 当前仓库距离公开发布还有什么

依据本次本地仓库检查，DevPanel 已有产品设计、契约、实现和实测记录，具备做源码预览的基础；交付形态还需要整理。

| 检查项 | 当前证据 | 发布建议 |
| --- | --- | --- |
| 开源入口 | Git 跟踪文件中缺根 README、LICENSE、CONTRIBUTING、SECURITY 和 GitHub workflow；现有 [Mac README](../apps/mac/README.md)主要服务本地构建。 | 补定位、截图、系统条件、构建与卸载步骤、支持边界；明确贡献和问题报告入口。 |
| 安装与分发 | Mac README 说明 App 只含 UI，daemon 需要 Node 24+，CLI 依赖源码仓库；目前 ad-hoc 签名，未完成正式发行公证。 | 源码预览可如实写明依赖；面向普通用户推广前做独立安装包与干净机器验收。 |
| 平台条件 | [Package.swift](../apps/mac/Package.swift)声明 macOS 14+、Swift 6；文档有个人绝对路径。 | 清理可公开文档中的机器特定路径，明确构建条件与支持机型。 |
| 验收证据 | [v0.2 计划](plan-v0.2.md)和[后端设计](backend-design.md)有实测记录；通知、跨机器验证仍需补齐，性能样本局限于本机短测。 | 对外区分已验收与待验证，不把本机结果泛化为兼容性或性能保证。 |
| 版本状态 | v0.3 有大量未提交改动；[agent skill](../skills/devpanel/SKILL.md)及其 onboarding/config/v0.3 参考文件已纳入 Git。 | 选择清晰的发布快照，区分稳定能力和预览能力，避免把当前工作区直接标为稳定版。 |

根 `package.json` 的 `private: true` 是防止误发 npm，不阻止 GitHub 开源。此次 `git remote -v` 没有输出，只说明当前 checkout 未配置 remote，不能据此判断 GitHub 上是否已有仓库。

[GitHub 官方许可说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)明确：公开仓库并不自动授予通常意义的开源使用、修改和再分发权。若目标是降低采用和贡献门槛，可以考虑 [MIT](https://choosealicense.com/licenses/mit/)；它允许商业使用及在保留许可声明等条件下再分发，不能防止他人做闭源商业版本。最终许可证由维护者选择，本次未代为添加。

## 建议的验证顺序

1. **先把源码预览整理到别人能复现。** 确定名称和许可证，写好根 README、演示、版本边界与构建步骤，检查公开内容和历史中的个人信息、凭据及第三方素材来源。不要等功能清单无限增长。
2. **再验证安装与真实使用。** 找 10—15 位符合目标场景的开发者；这一人数是试验建议，不是需求统计。让他们在自己的项目上完成安装、配置、启动、查看日志、重启和卸载，记录每一步卡点。
3. **用两周留存判断价值。** 观察有多少人独立完成首次使用、第二周仍主动使用、是否真的让 agent 经 CLI 管服务，以及为何继续用或退回原工具。star 可作传播信号，核心是持续使用。
4. **最后再决定商业投入。** 若用户确实长期使用并反复提出同类付费需求，再讨论支持服务或收费能力；当前更适合积累作品、用户反馈和社区信任，不应按已有收入前景安排投入。

开源发布本身没有在本次调研中执行：未推送仓库、修改可见性、添加许可证或改动用户稳定版。
