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
            content(hasRun: viewedId != nil, onTarget: onTarget, live: live)
            if isTask { TaskLogsFooter(model: model, onTarget: onTarget, live: live, toast: toast) }
            else { footer(onTarget: onTarget, live: live) }
        }
        .onChange(of: app?.logFocus) { _, _ in searchFocused = true }
        .onChange(of: viewedId) { _, _ in
            follow = true
            session.markSeen()
        }
        .onChange(of: session.revision) { _, _ in
            if follow { session.markSeen() }
        }
    }

    // MARK: Toolbar

    private func toolbar(runs: [LogRun], viewedId: RunID?, hasLines: Bool) -> some View {
        VStack(spacing: 6) {
            if !runs.isEmpty {
                HStack {
                    RunPicker(model: model, ref: ref, runs: runs, viewedId: viewedId, currentId: currentRunId)
                    Spacer(minLength: 0)
                }
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
                Button("复制摘要") {
                    guard let viewedId, let client = model.client else { return }
                    Task { @MainActor in
                        do {
                            let digest = try await client.digest(viewedId)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(digest.text, forType: .string)
                            toast = "已复制摘要"
                            toastTask?.cancel()
                            toastTask = Task { try? await Task.sleep(for: .seconds(2)); toast = nil }
                        } catch { toast = "复制摘要失败：\(error.localizedDescription)" }
                    }
                }
                .fixedSize()
                .disabled(viewedId == nil || model.client == nil)
                IconButton(symbol: "⧉", size: 26, help: "复制：有选区时复制选区，否则复制已加载的全部", enabled: hasLines) {
                    copyLines()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
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
