你负责修复 DevPanel v0.4 review 发现的问题。仓库：/path/to/DevPanel，分支 `main`（当前 `6cab318` 之后）。环境同 v0.4：macOS 27、Xcode 27.1、Swift 6.4、Node 24、pnpm 12。

背景：你已按 `prompts/codex-v0.4.md` 完成 v0.4 六个阶段。Claude 对 `feca7b7..6cab318` 做了两轴 review（规范 / 需求），本说明列出需要修的项。

**直接在 `main` 上修，不再开工作树。** 每一组修复自检后单独提交到本地 `main`，不推送。下面按优先级排序：额度不够时先做完前面的组，未完成的组写进汇报。

---

## 0. 先读

1. `AGENTS.md`、`prompts/codex-v0.4.md` 第 1 节“硬性规则”：全部继续有效，包括不碰用户稳定版、进程只按 pid + 启动时间核验后发信号、测试一律隔离 `DEVPANEL_HOME`、不推送不发布。
2. `contract/CHANGES.md` 的“待决提案”（共 5 条）、`contract/api.md` §2、§9、§13–§16。
3. `docs/plan-v0.4.md`：你自己的实现记录。本次修复记录追加在末尾。

## 1. 契约决定（第 1 组，先做）

**用户把这份说明交给你，即表示确认接受“待决提案”中的全部 5 条**：
- v1.3-D 关闭管理服务不经过托管规则；
- v1.3-B Python Traceback 合为一个错误块；
- v1.3-A 就绪端口禁止引用敏感选项；
- v1.3-A 删除选项写回就绪端口的类型；
- v1.3-B 日志级别标题区分大小写。

请按 `AGENTS.md` 的流程：
- 把 5 条的语义写进 `contract/api.md`：§2 的 shutdown 行、§13、§14、§16 的相应位置；
- 需要时同步 `packages/contract/src/index.ts` 的注释（这 5 条都不改类型）；
- 把它们移到“已生效”，状态写“用户确认（2026-10-22）”。

除这 5 条外，不改契约。修复中再发现契约问题，照旧写新的待决提案。

## 2. 修复项

### 第 1 组：契约落地与行为缺陷

1. **关闭管理服务绕过托管规则**（v1.3-D）。`packages/daemon/src/server.ts` 的 `/daemon/shutdown` 现在以请求方身份 `submit` 停止操作，造成两个问题：
   - 界面“停止所有服务并退出管理服务”会让所有服务进入暂停；
   - 有锁定服务时，CLI `daemon stop --stop-services` 在已经停掉其他服务和任务之后失败。

   改为：
   - shutdown 发起的停止不做规则判断、不产生暂停；
   - 已有的暂停与锁定保持不变；
   - 动态照常记录。

   mock 同步。测试：界面 shutdown 后没有暂停；锁定服务存在时 CLI shutdown 成功；已有的暂停在 shutdown 后保留。
2. **`logs` 参数回归**。`packages/cli/src/main.ts` 的 `logs` 现在对所有调用都拒绝 `--service` 与 `--run` 同时出现，但 api.md §9 原有用法 `logs <project-id> --service <id> [--run <run-id>]` 允许两者同时出现。
   - 不带 `--digest` / `--after-seq` 时，恢复 v0.3 的行为；
   - 带这两个参数的新用法按 §9 的 `(--service | --run)` 二选一；
   - 加回归测试，覆盖 v0.3 的全部 `logs` 组合。
3. **Python Traceback**（v1.3-B）：异常行并入 Traceback 块，并以异常行作为签名。daemon 摘要与 Swift 日志折叠都改。
4. **“最后一个错误块”的含义**：§14 的预算顺序“第一个错误块、最后一个错误块”指时间上最后出现的块，即 `lastOccurrenceSeq` 最大的块。现在取的是 Map 插入顺序中的最后一个（即最后首次出现的签名），要改正并加测试。
5. **摘要标题的行号范围**：`digest-text.ts` 与 Swift `LogDigest` 的标题现在打印“行 (afterSeq ?? 0)+1–…”。早期日志已被丢弃（`truncated`）或指定了 `afterSeq` 时，起点不对。改为实际扫描到的范围：起点为 `lastSeq − scannedLines + 1`。两边实现一致，golden 样例覆盖这种情况。
6. **已停止的服务仍显示“已就绪”**：`ServiceTable.swift`、`InspectorView.swift` 中的就绪标记现在取 `currentRun ?? lastRun`。改为只看 `currentRun`；历史就绪用时留在运行记录中显示。
7. **`project rules` 文本**：目前只加了 `DEVPANEL_AGENT`。按产品 v0.4 §2.4、§8 补充四点：
   - 接入新项目时登记就绪条件；
   - 启停用 `--wait-ready`；
   - 读日志优先 `--digest`，修改后用 `--after-seq`；
   - 退出码 11 / 12 的含义。

   与 `skills/devpanel/` 的措辞保持一致。

### 第 2 组：测试与进程安全

8. **`packages/daemon/test/activity.test.ts` 泄漏进程**。`finally` 里按 `m.runs` 收集要清理的进程，但此时有两个问题：
   - `m` 已被替换成新的 Manager；
   - `m.remove(pid)` 已经删除了全部运行。

   所以收集结果为空，fixture 漏清。这个测试的等待（`settle`、`while (!endedAt)`）也没有上限，超时时 `finally` 根本不会执行。

   用户机器上实际遗留过一个 `service.mjs silent`（启动于 09:37:09，临时目录 `dp-actor-*`），Claude 已核对身份后停掉。

   要求：
   - 测试过程中**随时记录**每个进程的身份（pid + 启动时间），在 `t.after` 中清理；
   - 等待加上限；
   - 审查本次新增的全部测试（activity、policy、ready、digest，以及 CLI / mock 的对应测试）有没有同类问题；
   - 加一道检查：全量测试结束后，本次运行记录过身份的 fixture 进程必须全部消失，否则测试失败。
9. **mock 不得直接引用 daemon 实现**。`tools/mock-daemon/src/engine.ts`、`validate.ts` 引用了 `packages/daemon/src/ready.ts`，`server.ts` 引用了 `packages/daemon/src/digest.ts`。mock 应只依据契约模拟：
   - 就绪：改为 mock 自己的简化实现；
   - 摘要：改为返回固定样例，样例可以取自 golden 数据文件。
10. **golden 样例**：现在只有 `test-fixtures/digest/repeated.*` 一组。补充以下用例，CLI 与 Swift 两边的测试都读同一批文件：
    - 无错误；
    - 预算不足、有 `omitted`；
    - 指定 `afterSeq`；
    - `truncated`；
    - Python Traceback（含异常行）；
    - `repeat`。
11. **`scripts/release-smoke.mjs`**：
    - 先检查输出中没有敏感值，再写 `result.json`；
    - `finally` 中某个停止步骤抛错时，仍要执行 `daemon stop` 并核验没有残留进程。

### 第 3 组：超出范围的改动

12. **`activity --before`**：§9 只定义了 `[--limit]`。删除这个 CLI 参数（HTTP 路由的 `before` 保留）。
13. **Swift `RunProcessInfo.startedBy`**（`apps/mac/Sources/DevPanelKit/Contract/Runtime.swift`）：契约中的 `ProcessInfo` 没有这个字段，而且它插在 `startedAt` 的注释和字段之间。删除它。
14. **`CONFIG_CONFLICT` 的 `diff` 从整体一条改为按路径逐条**：两种写法都符合 §3，按路径更好，予以保留。但要确认三点，并在 `docs/plan-v0.4.md` 记录这项行为变化：
    - 敏感值全部遮盖（加测试）；
    - 原生程序与 skill 中依赖旧格式的地方已经同步；
    - mock 一致。
15. **CLI 安装器同时链接 `devpaneld`**：产品 v0.4 §6 已更新为两者都链接，不需要改代码。

### 第 4 组：代码质量（额度允许再做）

16. **重复代码**：
    - daemon 与 mock 的 `activity.ts` / `policy.ts` 几乎逐字相同。mock 只保留模拟所需的最小逻辑，不要整份复制；
    - `configDiff` 跳过的键与 `params.ts` 的 `comparable()` 重复，抽成一处；
    - `manager.ts` 中两处 `(timeoutSec ?? 120) * 1000` 抽成常量或函数；
    - `params.ts` 中两处就绪端口占位符判断合并。
17. **`server.ts` 同时传 `client` 与 `actor`**：`actor.client` 已经包含 client，改为只传 `actor`，`manager` 的默认参数同步。
18. **Swift 中 `LogDigestBlock.kind`、`ReadyCheck.kind` 等契约枚举**：用项目已有的开放枚举类型，不要用裸 `String`。
19. **mock `server.ts` 里构造 `actor` 后 `void actor` 的写法**：只是为了触发校验异常，改成显式的校验函数。
20. **新增 TS 文件的引号与空格风格**：与所在包的现有文件保持一致（双引号、正常空格）。只改本次新增的代码。

## 3. 不做

- 管理服务重启后接回旧管道。产品 v0.4 §9 已改为：等待中的运行在无法续接时为“未知”，作为已知限制。`readiness` 中从未被调用的续接代码可以删除，或者保留并注明用途，二选一，在汇报里说明。
- `ERROR` 只认大写导致 `npm ERR!`、tsc 的 `error TS…` 不被识别：本次不处理，在汇报中列为后续候选。

## 4. 质量与汇报

- 每次提交前：`pnpm typecheck`、`pnpm test`（隔离 `DEVPANEL_HOME`）、`cd apps/mac && swift build && swift test` 全部通过，0 编译警告；涉及发布脚本的组再跑一次 `pnpm release:local` 与 smoke 验证。
- 全部完成后：确认没有任何 `test/fixtures/service.mjs` 进程残留，并删除已合并的 `codex/v04-ai`、`codex/v04-supervision` 分支（`git branch -d`，不用 `-D`）。
- 在 `docs/plan-v0.4.md` 末尾追加“review 修复记录”：每项对应的提交、测试结果、未完成项。
- 汇报：
  1. 每组的提交与完成情况；
  2. 测试数量与耗时；
  3. 孤儿进程检查结论；
  4. 契约改动；
  5. 未完成项与原因；
  6. 需要用户手动验证的交互。
