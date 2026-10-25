import DevPanelKit
import SwiftUI

/// One row per service; shared and unreferenced options stay visible in their own rows.
struct ProjectOptionGroups: View {
    let model: AppModel
    let project: ProjectView
    let prefs: ViewPreferences

    var body: some View {
        let expanded = prefs.optionsExpanded(project.id)
        // Read the cached option presentation only, never the raw stats or a clock.
        let groups = model.paramGroups(project.id)
        let chips = groups.flatMap(\.chips)
        let pending = chips.filter(\.pending).count
        VStack(alignment: .leading, spacing: 12) {
            Button { prefs.toggleOptionsExpanded(project.id) } label: {
                HStack(spacing: 6) {
                    Text("选项 · \(chips.count) 项" + (pending > 0 ? " · \(pending) 项待生效" : ""))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(pending > 0 ? Theme.amber : Theme.text2)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pending > 0 ? "已修改的选项将在服务下次启动时生效" : "展开或收起项目选项")
            .accessibilityValue(expanded ? "已展开" : "已收起")
            .accessibilityIdentifier("options-disclosure-" + project.id)
            if expanded {
                ForEach(groups) { group in
                    HStack(alignment: .top, spacing: 12) {
                        HStack(spacing: 6) {
                            ServiceIdentityMark(color: group.serviceId.map { Theme.process(ProcessPalette.index(of: $0, in: project)) } ?? Theme.text3)
                            Text(group.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.text2)
                                .lineLimit(1)
                        }
                        .frame(width: 64, height: 24, alignment: .leading)
                        .help(group.title)
                        FlowLayout(spacing: 6) {
                            ForEach(group.chips) { chip in
                                OptionChipButton(model: model, project: project, chip: chip)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
