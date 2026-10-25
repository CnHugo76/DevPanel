# v0.4 AI 闭环线实现与验收片段

## 阶段 3：日志摘要

- 实现：新增 daemon `digest.ts`，按请求遍历既有有界日志，不另外读取/复制整个日志文件；错误标题、数字签名、重复次数、ANSI 清理、1 KiB UTF-8 截行、Java 原因链折叠、Python 代码行及预算优先级。服务/任务共用 `/runs/:id/digest`。
- CLI：`logs --digest --after-seq --max-bytes --json`；普通日志增量对应 `after`；显式 `--service` 与 `--run` 互斥。
- 原生：当前查看运行的“复制摘要”与轻提示；堆栈保留前五帧、原因链后二帧，搜索和复制仍使用原文。
- mock：复用同一算法；端口冲突历史种子包含同错五十次、长 Java 原因链、Python 与正常 stderr。
- 文本 golden：`test-fixtures/digest/` 是 TypeScript 与 Swift 共同读取的唯一样例位置。
- 原生开始时 `docs/ui-design-v4.md` 尚不存在；沿用 v2/v3 工具栏与轻提示，无新增页面结构。
- 性能：32,825,344 字节 / 8,192 行输入，单次摘要 5.53ms（本机，普通长行；不包含已有日志采集开销），blocks 1,173 字节。
- 安全：新增 secret 环境变量/选项明文回归；摘要只消费已脱敏日志。开发均使用 `/tmp/dp-ai-check`，未调用稳定版或真实数据。
- 契约待决：§14(a) ERROR/FATAL/SEVERE 建议只认大写，已写 `contract/CHANGES.md`，契约正文和类型未改。
- 验证：pnpm typecheck 通过；pnpm test 全量通过；Swift build 无警告；Swift test 291/291；bundle.sh release 构建无警告并生成 ad-hoc .app（未启动或安装）。具体 pnpm 计数由合并验收统一汇总。
- 人工项：用户实际点击“复制摘要”后粘贴、折叠搜索与选区复制的桌面交互留待最终联调。无阻塞事项。

## 阶段 4：就绪

- daemon：新增 `ready.ts` 纯逻辑，校验日志文字、数值/number 选项端口、等待上限；`usedBy.where=ready`，删除引用选项 inline 时写回 JSON number；启动时单独快照就绪条件，进程配置快照排除 ready。
- 日志：采集 add 路径同步做有界子串判断；ANSI 清理，sys 不参与；partial 物理长行跨片段最多保留 1,024 字符。排查 secret 回归发现原采集器固定保留最长 secret 尾巴会让空闲服务的最后一行 READY 迟迟不发出，改为 KMP 前缀表只保留实际可能续接 secret 的后缀；跨 write/newline/长行脱敏仍覆盖。
- 端口：等待期间复用现有 ProcessScanner 原生 LISTEN 请求；退出 waiting 后不做额外请求。测试注入采样计数：第三次返回匹配监听端口进入 ready，之后再等待 1.1 秒计数不增加（常规资源/端口采样设为 60 秒以隔离额外请求）。
- 生命周期：超时只标记；spawn 失败、观察期退出、就绪前停止记录 ended-before-ready；旧运行总是补 not-configured。当前 daemon 的 §8 恢复不能重新取得旧管道，waiting 恢复为 unknown；不猜测日志证据，也不重新执行命令。私有快照、已处理 seq 和有界尾巴持久化，为将来可续接采集路径保留必要信息。
- HTTP：`ready/wait` 最长 60 秒，终态立即返回；任务运行明确 400/task-run。
- CLI：`start|restart --wait-ready [--ready-timeout]` 输出 CliStartReport，失败/超时附摘要，真实端口随报告；not-configured 提示写 stderr；no-wait 冲突在创建操作前拒绝；help 可发现新参数。已得到操作后，请求失败仍保留报告结构。
- 原生：可选解码/开放就绪状态；服务行和检查器显示等待/就绪/琥珀未就绪，悬停显示时间和依据；运行记录显示用时；每服务编辑卡新增就绪分区；ready 引用在删除选项预览中可见；超时通知仅窗口不在前台时发送。ui-design-v4 仍未出现，沿用现有分区和组件，无新增页面。
- mock：复用校验与判断函数，种子新增日志就绪、`${port}` 就绪、短超时、未配置四个虚拟服务；不执行真实项目命令。
- 测试：就绪配置/ANSI/sys/长行、日志真实命中、超时不停止、早退、端口采样计数、更新值快照、只改 ready 不标记进程配置变化、长轮询、任务400、任务摘要、恢复 unknown；CLI 0/1/8/11/未配置/冲突用法和 secret 环境变量/选项报告回归。POLICY_DENIED 的12沿用监督线 operationCode，由主线联调覆盖。
- 原生测试：294 项通过（新增3项：就绪配置往返与预览、表单校验、展示与未知枚举）。Swift build、test、release bundle 无编译警告。
- 待决提案：ready.port 引用 secret 按 PARAM_INVALID 拒绝；inline 写回为 number；与阶段3大写日志级别提案一起记录在 contract/CHANGES.md，未改冻结契约。
- 证据：`packages/daemon/test/ready.test.ts` 的“端口等待复用采样，达到就绪后停止额外读取；下次使用新选项”；32 MiB 有界日志实测 33,552,103 字节、8,054 行、6.36ms（`work-ai/.devpanel-dev/codex/v04/digest-32m-benchmark.json`），blocks 1,173 字节。此测量包含按日志上限截断，不含预先采集耗时。
- 手动项：复制摘要粘贴、就绪编辑表单、真实通知与悬停说明的桌面交互由阶段6统一截图和验收；当前无用户决策阻塞开发。
- 最终门槛：pnpm typecheck 通过；pnpm test daemon 90/90（94.11 秒）、CLI 18/18（2.68 秒）、mock 45/45（5.76 秒）、Web 52/52（0.107 秒）；Swift 294/294（3.043 秒）、build（2.04 秒）与 release bundle（29.52 秒）无编译警告。既有任务测试清理新增成功收尾后的幂等保护，首次 stopAllTasks 异常继续抛出，重复 after hook 不再操作已关闭 manager。
- 留证：全部关键日志、32 MiB benchmark 与进程清单已复制至主线 `.devpanel-dev/codex/v04/ai-evidence/`，供阶段6整合；未发现本次 dp-ready/dp-task 测试夹具或 dp-ai-check 运行残留。
