import DevPanelKit
import SwiftUI

struct ActionParameterSummary: View {
    let model: AppModel
    let runId: RunID
    @State private var detail: TaskRunDetail?
    @State private var failed = false
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let detail {
                if let params = detail.actionParams {
                    if !params.isEmpty {
                        DisclosureGroup(isExpanded: $expanded) {
                            ForEach(params) { p in
                                HStack(alignment: .top) { Text(p.label).foregroundStyle(Theme.text2); Spacer(); Text(p.display).textSelection(.enabled) }
                            }.padding(.top, 4)
                        } label: {
                            Text("本次参数 · " + params.map { "\($0.label)：\($0.display)" }.joined(separator: " · "))
                                .lineLimit(2).help("本次参数 · " + Format.shortRunId(runId))
                        }
                    }
                } else { Text("未保存操作参数快照").foregroundStyle(Theme.text3) }
            } else if failed { Text("参数快照暂不可用").foregroundStyle(Theme.text3) }
            else { Text("正在读取本次参数…").foregroundStyle(Theme.text3) }
        }.font(.system(size: 11.5)).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading).background(Theme.bar)
            .task(id: runId + String(model.isConnected)) {
                detail = nil; failed = false
                guard model.isConnected, let client = model.client else { failed = true; return }
                do { let value = try await client.taskRun(runId); if !Task.isCancelled { detail = value } }
                catch { if !Task.isCancelled { failed = true } }
            }
    }
}
