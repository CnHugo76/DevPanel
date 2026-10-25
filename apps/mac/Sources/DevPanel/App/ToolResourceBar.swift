import DevPanelKit
import SwiftUI

/// A quiet, always-visible account of the tool's own cost, separate from project totals.
struct ToolResourceBar: View {
    let model: AppModel
    @State private var showDetails = ProcessInfo.processInfo.arguments.contains("--bench-resource-popover")
    private let snapshotDetails = ProcessInfo.processInfo.arguments.contains("--tool-resources-details")
        && ProcessInfo.processInfo.arguments.contains("--snapshot")

    var body: some View {
        Group {
            let readout = model.toolResources.currentReadout
            Button { showDetails.toggle() } label: {
                HStack(spacing: 8) {
                    Text("DevPanel 自身").fontWeight(.medium)
                    Text("·")
                    Text("CPU \(Metrics.cpu(readout.total, active: true).text)")
                    Text("·")
                    Text("内存 \(Metrics.memory(readout.total, active: true).text)")
                    if let notice = readout.notice {
                        Text(notice).foregroundStyle(Theme.text3)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "info.circle").foregroundStyle(Theme.text3)
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看界面、管理进程和辅助进程的资源占用；不含业务项目")
            .accessibilityLabel("DevPanel 自身，CPU \(Metrics.cpu(readout.total, active: true).text)，内存 \(Metrics.memory(readout.total, active: true).text)，\(readout.notice ?? "")")
            .accessibilityHint("打开资源明细")
            .background(Theme.bar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                ToolResourceDetails(readout: readout)
            }
            .overlay(alignment: .bottomLeading) {
                if snapshotDetails {
                    ToolResourceDetails(readout: readout)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                        .padding(.leading, 16)
                        .padding(.bottom, 38)
                }
            }
        }
    }
}

private struct ToolResourceDetails: View {
    let readout: ToolResourceReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DevPanel 自身").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("进程")
                    Text("CPU").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("内存").frame(maxWidth: .infinity, alignment: .trailing)
                }.foregroundStyle(Theme.text3)
                row("界面", sample: readout.interface)
                row("管理进程", sample: readout.daemon)
                row("辅助进程", sample: readout.helpers)
                Rectangle().fill(Theme.line).frame(height: 1).gridCellColumns(3)
                row("合计", sample: readout.total, total: true)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            if let notice = readout.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(Theme.amber)
            }
            Text("仅此界面、管理进程及其辅助进程，不含业务项目。\nCPU 100% = 一个逻辑核心满载。内存优先使用 footprint，包含系统计入进程的压缩及换出内存；回退时标注 RSS。每 2 秒更新。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 370)
        .background(Theme.card2)
    }

    private func row(_ name: String, sample: ResourceSample, total: Bool = false) -> some View {
        let cpu = Metrics.cpu(sample, active: true)
        let memory = Metrics.memory(sample, active: true)
        return GridRow {
            Text(name).foregroundStyle(total ? Theme.text : Theme.text2)
            Text(cpu.text).frame(maxWidth: .infinity, alignment: .trailing).help(cpu.help ?? "")
            Text(memory.text).frame(maxWidth: .infinity, alignment: .trailing)
                .help(sample.note ?? memory.help ?? "")
        }
        .foregroundStyle(sample.status == .unavailable ? Theme.text3 : Theme.text2)
        .fontWeight(total ? .semibold : .regular)
        .help(sample.note ?? "")
    }
}
