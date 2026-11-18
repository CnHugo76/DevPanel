import DevPanelKit
import SwiftUI

/// Capture the clicked service and run so live list updates never change an open diagnosis.
struct OverviewDiagnosis: Identifiable {
    let projectName: String
    let problem: OverviewProblem
    let digest: LogDigest?
    var id: ServiceRef { problem.ref }
}

struct OverviewProblemSheet: View {
    let model: AppModel
    let diagnosis: OverviewDiagnosis
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: LogDigest?
    @State private var error: String?
    @State private var attempt = 0
    @State private var copied = false

    private var problem: OverviewProblem { diagnosis.problem }
    private var title: String {
        diagnosis.projectName == problem.serviceName ? diagnosis.projectName : diagnosis.projectName + " · " + problem.serviceName
    }
    private var requestID: RunID? { model.isConnected ? problem.runID : nil }

    var body: some View {
        Group {
            if let digest = loaded ?? diagnosis.digest {
                let summary = problem.isFailure ? "运行失败 · " + (problem.evidence(in: digest) ?? problem.summary) : problem.summary
                ErrorContextSheet(context: ErrorContext(runId: digest.runId, digest: digest), title: title, summary: summary,
                    canOpenLog: model.runs(for: problem.ref).contains { $0.id == digest.runId },
                    openLog: {
                        dismiss()
                        model.showRunLog(digest.runId, of: problem.ref)
                    })
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title).font(.headline)
                    Text(problem.summary).textSelection(.enabled)
                    if problem.runID == nil { Text("此次异常没有可定位的运行日志。").foregroundStyle(.secondary) }
                    else if !model.isConnected { Text(Copy.staleReason) }
                    else if let error {
                        Text(error).foregroundStyle(.secondary)
                        Button("重新读取") { attempt += 1 }
                    } else { ProgressView("读取本次运行的错误上下文…").controlSize(.small) }
                    HStack {
                        Button(copied ? "已复制" : "复制给 AI") {
                            copy([title, problem.summary, problem.runID].compactMap { $0 }.joined(separator: " · "))
                            copied = true
                        }
                        Spacer()
                        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }.padding(20).frame(minWidth: 380)
            }
        }
        .task(id: Request(run: requestID, attempt: attempt)) {
            guard loaded == nil, diagnosis.digest == nil, let id = requestID, let client = model.client else { return }
            error = nil
            do {
                let result = try await client.digest(id)
                guard !Task.isCancelled else { return }
                if result.runId == id { loaded = result }
                else { error = "日志与所选运行不一致，请重新读取。" }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private struct Request: Equatable {
        let run: RunID?
        let attempt: Int
    }
}
