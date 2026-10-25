import AppKit
import DevPanelKit
import SwiftUI

/// The "日志" tab (ui-design v1 §5.4, v2 §4): search, run picker, follow, wrap, copy; history
/// banner; the lines; "↓ N 条新日志" pill; status line.
struct LogsTab: View {
    let model: AppModel
    let ref: LogOwner
    let project: ProjectView
    let currentRunId: RunID?
    init(model: AppModel, ref: ServiceRef, project: ProjectView, service: ServiceView) {
        self.init(model: model, ref: .service(ref), project: project, currentRunId: service.currentRun?.id)
    }
    init(model: AppModel, ref: LogOwner, project: ProjectView, currentRunId: RunID?) {
        self.model = model; self.ref = ref; self.project = project; self.currentRunId = currentRunId
    }

    @Environment(AppController.self) private var app: AppController?
    @State private var follow = true
    @State private var controller = LogTextController()
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var diagnosticTask: Task<Void, Never>?
    @State private var diagnosticLoading = false
    @State private var errorContext: ErrorContext?
    @FocusState private var searchFocused: Bool
    @Environment(\.isStale) private var stale

    private var isTask: Bool { ref.isTask }
    private var session: LogSession { model.inspector.logs }
    private var search: LogSearchModel { model.inspector.search }

    var body: some View {
        let runs = model.runs(for: ref)
        let viewedId = model.viewedRunId(for: ref)
        let viewedRun = runs.first { $0.id == viewedId }
        let onTarget = session.target?.owner == ref && session.target?.runId == viewedId && viewedId != nil
        let live = viewedRun.map { $0.endedAt == nil } ?? false
        VStack(spacing: 0) {
            toolbar(runs: runs, viewedId: viewedId, hasLines: onTarget && !session.buffer.isEmpty)
            if model.isViewingHistory(ref), let viewedRun {
                historyBanner(viewedRun)
            }
            if let viewedRun, let problem = problem(viewedRun) {
                HStack(spacing: 8) {
                    Text("所选运行 · " + problem).foregroundStyle(Theme.amber)
                    Spacer(minLength: 0)
                    Button("查看错误上下文") { diagnose(.showError, runId: viewedRun.id) }
                        .disabled(diagnosticLoading || model.client == nil)
                }
                .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.amberSoft)
            }
            if onTarget && (stale || session.status.gap != nil || session.status.reconnecting) {
                recoveryNote
            }
            content(hasRun: viewedId != nil, onTarget: onTarget, live: live)
            if isTask { TaskLogsFooter(model: model, onTarget: onTarget, live: live, toast: toast) }
            else { footer(onTarget: onTarget, live: live) }
        }
        .onChange(of: app?.logFocus) { _, _ in searchFocused = true }
        .onChange(of: viewedId) { _, _ in
            follow = true
            session.markSeen()
            cancelAuxiliaryWork()
            toast = nil
        }
        .onChange(of: session.revision) { _, _ in
            if follow { session.markSeen() }
        }
        .onDisappear { cancelAuxiliaryWork(); toastTask?.cancel() }
        .sheet(item: $errorContext) { context in
            ErrorContextSheet(context: context)
        }
    }

    // MARK: Toolbar

    private func toolbar(runs: [LogRun], viewedId: RunID?, hasLines: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if !runs.isEmpty {
                    RunPicker(model: model, ref: ref, runs: runs, viewedId: viewedId, currentId: currentRunId)
                }
                Spacer(minLength: 0)
                if diagnosticLoading { ProgressView().controlSize(.mini) }
                Menu("排障") {
                    Button("复制排障信息") { if let viewedId { diagnose(.copyReport, runId: viewedId) } }
                    Button("查看错误上下文") { if let viewedId { diagnose(.showError, runId: viewedId) } }
                    Button("复制日志摘要") { if let viewedId { diagnose(.copyDigest, runId: viewedId) } }
                }
                .fixedSize().disabled(viewedId == nil || model.client == nil || diagnosticLoading)
                Button("搜索保留日志…") {
                    if let viewedId { model.inspector.retainedSearch = RetainedLogSearchTarget(runId: viewedId, query: search.query) }
                }
                .fixedSize().disabled(viewedId == nil || model.client == nil)
            }
            HStack(spacing: 6) {
                searchField
                ToggleChip(title: "跟随", on: follow && !session.buffer.detached, help: "新日志到达时滚动到底部") {
                    if follow { follow = false } else { jumpToLatest() }
                }
                .disabled(runs.first { $0.id == viewedId }?.endedAt != nil || viewedId == nil)
                ToggleChip(title: "精简", on: model.inspector.compactPrefixes, help: "精简 Java 日志前缀：保留时间、级别、类名和正文；关闭查看完整前缀") {
                    model.inspector.compactPrefixes.toggle()
                }
                ToggleChip(title: "折叠", on: model.inspector.foldStacks, help: "折叠连续堆栈；关闭可展开全部原文") {
                    model.inspector.foldStacks.toggle()
                }
                ToggleChip(title: "↩︎", on: model.inspector.wrap, help: "自动换行") {
                    model.inspector.wrap.toggle()
                }
                IconButton(symbol: "⧉", size: 26, help: "复制：有选区时复制选区，否则复制已加载的全部", enabled: hasLines) {
                    copyLines()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var recoveryNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(session.status.gap != nil
                 ? "采集曾中断，正在从最后收到的行继续；保留期内可通过「搜索保留日志」核对缺口。"
                 : "连接中断，正在重连；已有日志可继续查看，恢复连接后从已收到的位置继续。")
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试连接") { model.retryNow(); session.connectionRestored() }
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.amber)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.amberSoft)
    }

    private func problem(_ run: LogRun) -> String? {
        switch run {
        case .service(let value):
            if value.state == .failed { return value.stateText }
            if value.ready?.state == .timedOut { return "进程仍在运行 · 就绪超时" }
            return nil
        case .task(let value): return value.state == .failed || value.state == .timedOut ? value.state.title : nil
        }
    }

    private enum DiagnosticAction { case copyReport, copyDigest, showError }

    private func diagnose(_ action: DiagnosticAction, runId: RunID) {
        guard let client = model.client else { return }
        diagnosticTask?.cancel()
        diagnosticLoading = true
        diagnosticTask = Task { @MainActor in
            defer { if !Task.isCancelled { diagnosticLoading = false } }
            do {
                if action == .copyDigest || action == .showError {
                    let digest = try await client.digest(runId)
                    guard !Task.isCancelled, model.viewedRunId(for: ref) == runId, digest.runId == runId else { return }
                    if action == .copyDigest { copy(digest.text); showToast("已复制 \(Format.shortRunId(runId)) 的日志摘要") }
                    else { errorContext = ErrorContext(runId: runId, digest: digest) }
                } else {
                    let report = try await TroubleshootingReport.load(client: client, owner: ref, runId: runId)
                    guard !Task.isCancelled, model.viewedRunId(for: ref) == runId else { return }
                    copy(report.text)
                    showToast("已复制 \(Format.shortRunId(runId)) 的排障信息")
                }
            } catch {
                guard !Task.isCancelled, model.viewedRunId(for: ref) == runId else { return }
                showToast("排障信息读取失败：\(error.localizedDescription)")
            }
        }
    }

    private func cancelAuxiliaryWork() {
        diagnosticTask?.cancel()
        diagnosticLoading = false
        errorContext = nil
        model.inspector.retainedSearch = nil
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            if search.query.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            TextField("搜索已加载的日志", text: Binding(get: { search.query }, set: { search.setQuery($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
                .onKeyPress(.return, phases: .down) { press in
                    jump(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.downArrow) { jump(1); return .handled }
                .onKeyPress(.upArrow) { jump(-1); return .handled }
                .onExitCommand {
                    search.setQuery("")
                    searchFocused = false
                }
                .frame(minWidth: 56)
                .layoutPriority(1)
            if !search.query.isEmpty {
                Text(search.counterText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(search.matches.isEmpty ? Theme.red : Theme.text3)
                    .lineLimit(1)
                    .fixedSize()
                HStack(spacing: 0) {
                    navButton("chevron.up", "上一个（⇧↩）") { jump(-1) }
                    navButton("chevron.down", "下一个（↩）") { jump(1) }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 120, maxWidth: .infinity)
        .frame(height: 26)
        .layoutPriority(1)
        .background(Theme.graySoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(searchFocused ? Theme.accent : Theme.line))
    }

    private func navButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(search.matches.isEmpty)
        .help(help)
    }

    /// ⌘F focuses the search field.
    // MARK: Banner

    private func historyBanner(_ run: LogRun) -> some View {
        let now = model.displayNow(Date())
        let back = currentRunId != nil ? "回到当前运行" : "回到最近一次运行"
        return HStack(spacing: 6) {
            Text("正在查看历史运行 \(Format.shortRunId(run.id))（\(run.rangeText(now: now))），不会追加新日志 ·")
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            Button(back) { model.chooseRun(nil, for: ref) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent2)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.amberSoft)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.amber.opacity(0.35)).frame(height: 1) }
    }

    // MARK: Body

    @ViewBuilder
    private func content(hasRun: Bool, onTarget: Bool, live: Bool) -> some View {
        let count = onTarget ? session.buffer.count : 0
        if let empty = LogEmptyState.make(hasRun: hasRun, status: onTarget ? session.status : loadingStatus, lineCount: count, live: live) {
            emptyView(empty)
        } else if !onTarget || count == 0 {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogTextView(
                buffer: session.buffer, epoch: session.epoch, revision: session.revision,
                compactPrefixes: model.inspector.compactPrefixes, foldStacks: model.inspector.foldStacks, wrap: model.inspector.wrap, follow: follow && !session.buffer.detached,
                matches: search.matches, currentMatch: search.current, searchVersion: search.version,
                controller: controller,
                onUserScroll: { atBottom in
                    follow = atBottom
                    if atBottom {
                        session.markSeen()
                        if session.buffer.detached { Task { await session.loadNewer() } }
                    }
                },
                onNearTop: { Task { await session.loadOlder() } })
            .overlay(alignment: .bottom) { newLinesPill }
        }
    }

    private var loadingStatus: LogStatus {
        var s = LogStatus()
        s.loading = true
        return s
    }

    @ViewBuilder private var newLinesPill: some View {
        let unseen = session.unseen
        if (!follow && unseen > 0) || session.buffer.detached {
            Button(action: jumpToLatest) {
                Text(!follow && unseen > 0 ? "↓ \(Format.count(unseen)) 条新日志 · 跳到最新" : "↓ 跳到最新")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
    }

    private func emptyView(_ state: LogEmptyState) -> some View {
        VStack(spacing: 8) {
            if let title = state.title {
                Text(isTask && state == .neverRun ? "此任务尚未运行" : title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Text(isTask && state == .neverRun ? "点击「运行」后，输出会显示在这里。注册项目和保存配置不会执行命令。" : state.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if state == .neverRun, let service = ref.service, let config = model.serviceConfig(service.projectId, service.serviceId) {
                Text(CommandText.join(config.command))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
        }
        .padding(28)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private func footer(onTarget: Bool, live: Bool) -> some View {
        Group {
            let items = onTarget
                ? LogFooter.items(
                    status: session.status, buffer: session.buffer, live: live, stale: stale,
                    now: .distantPast, logBytesPerRun: ref.isTask ? model.daemon?.limits.logBytesPerTaskRun : model.daemon?.limits.logBytesPerRun)
                : []
            FlowLayout(spacing: 12) {
                if let toast {
                    Text(toast).foregroundStyle(Theme.green)
                }
                ForEach(items) { item in
                    Text(item.text).foregroundStyle(color(item.tone))
                }
                QuietFooterTail(model: model, lastLineAt: onTarget && live ? session.status.lastLineAt : nil,
                                count: items.count + (toast == nil ? 0 : 1))
            }
            .font(.system(size: 11.5))
            .monospacedDigit()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    private func color(_ tone: LogFooterItem.Tone) -> Color {
        switch tone {
        case .muted: Theme.text3
        case .warning: Theme.amber
        case .negative: Theme.red
        }
    }

    // MARK: Actions

    private func jump(_ delta: Int) {
        guard let match = delta > 0 ? search.next() : search.previous() else { return }
        follow = false
        controller.reveal(match)
    }

    private func jumpToLatest() {
        if session.buffer.detached { session.reloadTail() }
        follow = true
        session.markSeen()
        controller.scrollToBottom()
    }

    private func copyLines() {
        if let selected = controller.selectedText, !selected.isEmpty {
            copy(selected)
            showToast("已复制选中的日志")
            return
        }
        let buffer = session.buffer
        guard !buffer.isEmpty else { return }
        copy(buffer.entries.map(\.displayText).joined(separator: "\n"))
        showToast("已复制已加载的 \(Format.count(buffer.count)) 行")
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }
}

/// `当前运行 | 上一次 | 更早` (mockup `.seg`); tooltips carry the time range and end state.
struct RunPicker: View {
    let model: AppModel
    let ref: LogOwner
    let runs: [LogRun]
    let viewedId: RunID?
    let currentId: RunID?

    var body: some View {
        let now = model.displayNow(Date())
        HStack(spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                let on = run.id == viewedId
                let isCurrent = run.id == currentId
                if index > 0 { Rectangle().fill(Theme.line2).frame(width: 1) }
                Button {
                    model.chooseRun(run.id, for: ref)
                } label: {
                    Text(RunLabels.title(index: index, isCurrent: isCurrent))
                        .font(.system(size: 12))
                        .foregroundStyle(on ? Theme.accent2 : Theme.text2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(on ? Theme.accentSoft : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(RunLabels.title(index: index, isCurrent: isCurrent) + " · " + run.rangeText(now: now) + (isCurrent ? "" : " · " + run.stateText))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line2))
        .fixedSize()
    }
}

/// A small on/off text button (mockup `.tbtn`).
struct ToggleChip: View {
    let title: String
    let on: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(on ? Theme.accent2 : Theme.text2)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(on ? Theme.accent.opacity(0.45) : Theme.line2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
