import DevPanelKit
import SwiftUI

struct ErrorContext: Identifiable {
    var runId: RunID
    var digest: LogDigest
    var id: RunID { runId }
}

struct ErrorContextSheet: View {
    let context: ErrorContext
    var title = "错误上下文"
    var summary: String? = nil
    var canOpenLog = true
    var openLog: (() -> Void)? = nil
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let digest = context.digest
        let first = digest.blocks.first { $0.kind == .error }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let summary { Text(summary).font(.callout).foregroundStyle(Theme.text2) }
            Text("固定运行 \(context.runId)").font(.system(size: 11.5)).foregroundStyle(Theme.text3).textSelection(.enabled)
            if let first {
                Text("摘要内首个错误 · 行 \(first.firstSeq)–\(first.lastSeq) · 出现 \(first.occurrences) 次")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.red)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(first.lines.enumerated()), id: \.offset) { _, line in
                            Text("\(line.seq)  \(Ansi.strip(line.text))")
                            if let folded = line.folded {
                                Text("… 摘要折叠了 \(folded.lines) 行；用日志搜索查看原文。")
                                    .foregroundStyle(Theme.text3)
                            }
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("摘要中未识别出错误块。请检查退出信息、实际启动命令，或用关键词搜索保留日志。")
                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Text("摘要扫描了 \(digest.scannedLines) 行；仅展示保留范围内的错误证据。")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
            if digest.truncated {
                Text("较早日志已被保留上限淘汰。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.amber)
            }
            if let openLog {
                HStack {
                    Button("查看本次运行日志", action: openLog).disabled(!canOpenLog)
                    Spacer()
                    Button(copied ? "已复制" : "复制给 AI") {
                        copy([title, summary ?? "", digest.text].joined(separator: "\n"))
                        copied = true
                    }
                }
            }
        }
        .padding(20).frame(minWidth: 620, idealWidth: 760, minHeight: 400, idealHeight: 560)
        .background(Theme.window)
    }
}
