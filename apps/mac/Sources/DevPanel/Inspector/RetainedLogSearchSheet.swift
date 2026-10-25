import DevPanelKit
import SwiftUI

struct RetainedLogSearchHost: ViewModifier {
    let model: AppModel
    @Environment(\.inlineSheets) private var inline
    private var target: Binding<RetainedLogSearchTarget?> {
        Binding(get: { model.inspector.retainedSearch }, set: { model.inspector.retainedSearch = $0 })
    }
    func body(content: Content) -> some View {
        content
            .sheet(item: inline ? .constant(nil) : target) { target in
                if let client = model.client {
                    RetainedLogSearchSheet(client: client, runId: target.runId, query: target.query)
                }
            }
            .overlay {
                if inline, let target = model.inspector.retainedSearch, let client = model.client {
                    GeometryReader { proxy in
                        ZStack {
                            Color.black.opacity(0.28)
                            RetainedLogSearchSheet(client: client, runId: target.runId, query: target.query)
                                .frame(width: min(760, proxy.size.width - 40), height: min(620, proxy.size.height - 40))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
    }
}

/// Owns one explicitly requested search, separate from the continuously updated log session.
struct RetainedLogSearchSheet: View {
    let client: DaemonClient
    let runId: RunID
    @State private var query = ""
    @State private var caseSensitive = false
    @State private var search = RetainedLogSearch()
    @Environment(\.dismiss) private var dismiss

    init(client: DaemonClient, runId: RunID, query: String = "") {
        self.client = client
        self.runId = runId
        _query = State(initialValue: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("搜索保留日志").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("运行 \(runId) · 搜索开始时固定日志范围，新日志需重新搜索。")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3).textSelection(.enabled)
            HStack(spacing: 10) {
                TextField("原文关键词（1–200 字符）", text: $query)
                    .textFieldStyle(.roundedBorder).onSubmit(start)
                Toggle("区分大小写", isOn: $caseSensitive).font(.system(size: 12))
                Button("搜索", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.isEmpty || query.unicodeScalars.count > 200)
            }
            Divider()
            results.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 760, minHeight: 440, idealHeight: 620)
        .background(Theme.window)
        .task { if !query.isEmpty { start() } }
        .onDisappear { search.cancel() }
    }

    private var fetch: RetainedLogSearch.Fetch {
        { request in
            try await client.searchLogs(request.runId, query: request.query, caseSensitive: request.caseSensitive,
                                        after: request.after, through: request.through)
        }
    }

    private func start() {
        let term = query
        let sensitive = caseSensitive
        Task { await search.search(runId: runId, query: term, caseSensitive: sensitive, fetch: fetch) }
    }

    @ViewBuilder private var results: some View {
        if let error = search.error {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.red)
                if search.request != nil {
                    Button("重试本页") { Task { await search.retry(fetch: fetch) } }
                }
                Text("搜索失败不表示没有匹配。若日志已过保留期，请选择仍保留的运行。")
                    .foregroundStyle(Theme.text3)
            }.font(.system(size: 12))
        } else if search.loading {
            ProgressView("正在搜索保留日志…").controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let page = search.page {
            if page.matches.isEmpty {
                VStack(spacing: 8) {
                    Text(page.hasMore ? "本页未找到匹配" : "当前搜索范围未找到更多匹配")
                        .font(.system(size: 14, weight: .medium))
                    Text(page.hasMore ? "仍有日志未扫描，点击「继续搜索」查看下一页。" : "可以换一个关键词重新搜索。")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(page.matches) { match in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("匹配行 \(match.line.seq)")
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent2)
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(match.before + [match.line] + match.after, id: \.seq) { line in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("\(line.seq)").foregroundStyle(Theme.text3)
                                                .frame(width: 52, alignment: .trailing)
                                            Text(Ansi.strip(line.text)).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .padding(.vertical, 3).padding(.horizontal, 6)
                                        .background(line.seq == match.line.seq ? Theme.accentSoft : .clear)
                                    }
                                }
                                .textSelection(.enabled)
                                .padding(5)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                }
                .id(search.pageNumber)
            }
        } else {
            Text("输入关键词后搜索本次运行仍保留的全部日志。每页最多 50 处匹配，显示前后各 2 行原文。")
                .font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let page = search.page {
                if page.truncated {
                    Label("较早日志已被保留上限淘汰；搜索不包含已丢失内容。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.amber)
                }
                Text("关键词「\(search.request?.query ?? "")」· 快照截至行 \(page.throughSeq) · 已扫描至行 \(page.scannedThroughSeq)")
                    .foregroundStyle(Theme.text3).lineLimit(2)
                HStack {
                    Text("第 \(search.pageNumber) 页 · \(page.matches.count) 处匹配").foregroundStyle(Theme.text2)
                    Spacer()
                    Button("上一页") { Task { await search.previous(fetch: fetch) } }.disabled(!search.canGoBack)
                    Button(page.hasMore ? "继续搜索" : "已到快照末尾") { Task { await search.next(fetch: fetch) } }
                        .disabled(!search.canGoForward)
                }
            } else {
                Text("搜索结果与实时日志窗口分别保存；重新搜索会取得新的日志快照。")
                    .foregroundStyle(Theme.text3)
            }
        }.font(.system(size: 11.5))
    }
}
