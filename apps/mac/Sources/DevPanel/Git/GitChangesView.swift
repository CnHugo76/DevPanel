import AppKit
import DevPanelKit
import SwiftUI

/// A compact change browser; grouping is independent of staging and file status.
struct GitChangesView: View {
    let model: AppModel
    let project: ProjectView
    let open: (GitFileKey) -> Void
    @Environment(AppController.self) private var controller: AppController?
    @State private var collapsed: [String: Set<String>] = [:]
    @State private var anchor: GitFileKey?
    @FocusState private var focused: Bool

    private var entries: [GitEntry] { model.git.statuses[model.gitScope(project.id).key]?.entries ?? [] }
    private var selected: Set<GitFileKey> { model.git.selections[model.gitScope(project.id).key, default: []] }
    private var disabled: Bool { !model.isConnected || model.git.busy.contains(model.gitScope(project.id).key) }
    private struct Section: Identifiable {
        let group: GitGroup
        let entries: [GitEntry]
        let rows: [GitFileListRow]
        var id: String { group.id }
    }
    private var sections: [Section] {
        GitGroup.allCases.compactMap { group in
            let filtered = entries.filter {
                group.contains($0) && (model.git.changeFilter == nil || $0.changeKind(staged: group == .staged) == model.git.changeFilter)
            }
            guard !filtered.isEmpty else { return nil }
            return Section(group: group, entries: filtered, rows: GitFileList.rows(
                filtered, layout: model.git.fileLayout, collapsed: collapsed[sectionKey(group), default: []]))
        }
    }

    var body: some View {
        let sections = sections
        let order = sections.flatMap { section in
            section.rows.compactMap { $0.entry.map { GitFileKey(path: $0.path, staged: section.group == .staged) } }
        }
        VStack(spacing: 0) {
            controls
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        Label("工作区干净", systemImage: "checkmark.circle").foregroundStyle(Theme.green).padding(18)
                    } else if sections.isEmpty {
                        Text("没有符合筛选条件的改动").foregroundStyle(Theme.text3).padding(18)
                    }
                    ForEach(sections) { section in
                        sectionHeader(section)
                        ForEach(section.rows) { row in
                            if let entry = row.entry {
                                fileRow(entry, staged: section.group == .staged, depth: row.depth, order: order)
                            } else {
                                directoryRow(row, group: section.group)
                            }
                        }
                    }
                }
            }
            .focusable().focused($focused)
            .onKeyPress(.space) {
                let visibleSelection = selected.intersection(Set(order))
                guard focused, !disabled, !visibleSelection.isEmpty else { return .ignored }
                stage(Array(visibleSelection), !visibleSelection.allSatisfy(\.staged)); return .handled
            }
            .onKeyPress(.return) {
                guard focused, model.isConnected, let file = order.first(where: selected.contains) else { return .ignored }
                open(file); return .handled
            }
        }
        .frame(minHeight: 140, maxHeight: .infinity)
        .onChange(of: order) { _, files in
            model.git.selections[model.gitScope(project.id).key]?.formIntersection(Set(files))
            if let anchor, !files.contains(anchor) { self.anchor = nil }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("显示方式", selection: Binding(get: { model.git.fileLayout }, set: { model.git.fileLayout = $0 })) {
                ForEach(GitFileListLayout.allCases) { layout in Text(layout.title).tag(layout) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 240)
            .help("目录分组按路径的第一级目录划分，例如 backend、frontend")
            Spacer(minLength: 0)
            Menu {
                Button { model.git.changeFilter = nil } label: {
                    if model.git.changeFilter == nil { Label("全部状态", systemImage: "checkmark") } else { Text("全部状态") }
                }
                Divider()
                ForEach(GitChangeKind.allCases) { kind in
                    Button { model.git.changeFilter = kind } label: {
                        if model.git.changeFilter == kind { Label(kind.title, systemImage: "checkmark") } else { Text(kind.title) }
                    }
                }
            } label: {
                Label(model.git.changeFilter?.title ?? "全部状态", systemImage: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("按修改、新增、删除等状态筛选")
        }
        .font(.system(size: 11)).padding(.horizontal, 12).padding(.bottom, 10)
    }

    private func sectionHeader(_ section: Section) -> some View {
        HStack {
            Text(section.group.title).fontWeight(.semibold)
            Text("\(section.entries.count)").monospacedDigit()
            Spacer()
            Button(model.git.changeFilter != nil
                   ? (section.group == .staged ? "取消暂存筛选项" : "暂存筛选项")
                   : (section.group == .staged ? "全部取消暂存" : "全部暂存")) {
                stage(section.entries.map { GitFileKey(path: $0.path, staged: section.group == .staged) }, section.group != .staged)
            }
            .buttonStyle(.borderless).disabled(disabled)
            .help(model.git.changeFilter == nil ? "操作此组的全部文件" : "仅操作此组符合筛选条件的文件")
        }
        .font(.system(size: 10.5)).foregroundStyle(Theme.text2)
        .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.card)
    }

    private func directoryRow(_ row: GitFileListRow, group: GitGroup) -> some View {
        let path = row.directory ?? ""
        let closed = collapsed[sectionKey(group), default: []].contains(path)
        return Button {
            if closed { collapsed[sectionKey(group), default: []].remove(path) }
            else { collapsed[sectionKey(group), default: []].insert(path) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: closed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold)).frame(width: 12)
                Image(systemName: "folder").foregroundStyle(Theme.text3)
                Text(row.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text("\(row.count)").font(.system(size: 10)).foregroundStyle(Theme.text3).monospacedDigit()
                Spacer(minLength: 0)
            }
            .font(.system(size: 11)).foregroundStyle(Theme.text2)
            .padding(.leading, 12 + indent(row.depth)).padding(.trailing, 12).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(path.isEmpty ? "仓库根目录" : path)
        .accessibilityValue(closed ? "已折叠" : "已展开")
    }

    private func fileRow(_ entry: GitEntry, staged: Bool, depth: Int, order: [GitFileKey]) -> some View {
        let file = GitFileKey(path: entry.path, staged: staged)
        let url = URL(fileURLWithPath: entry.path)
        let kind = entry.changeKind(staged: staged)
        let count = model.git.counts[model.gitScope(project.id).key]?[file]
        return HStack(spacing: 7) {
            Toggle("暂存 \(entry.path)", isOn: Binding(get: { staged }, set: { stage([file], $0) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(disabled)
            Image(systemName: kind.symbol).font(.system(size: 11)).foregroundStyle(kind.color).frame(width: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).foregroundStyle(kind.color).lineLimit(1).truncationMode(.middle)
                if model.git.fileLayout != .tree, entry.path.contains("/") {
                    Text(String(entry.path.dropLast(url.lastPathComponent.count + 1)))
                        .font(.system(size: 10)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                }
                if let previous = entry.origPath, previous != entry.path {
                    Text("原路径：\(previous)").font(.system(size: 10)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                }
                if entry.sensitiveName { Text("⚠ 可能含密钥").font(.system(size: 10)).foregroundStyle(Theme.amber) }
            }
            Spacer(minLength: 4)
            Text(kind.title).font(.system(size: 9.5, weight: .medium)).foregroundStyle(kind.color)
                .padding(.horizontal, 5).padding(.vertical, 2).background(kind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 3)).fixedSize()
            if let count {
                if count.binary { Text("二进制").font(.system(size: 10)).foregroundStyle(Theme.text3) }
                else {
                    (Text("+\(count.additions)").foregroundColor(Theme.green) + Text(" −\(count.deletions)").foregroundColor(Theme.red))
                        .font(.system(size: 10, design: .monospaced)).fixedSize()
                }
            }
            Button("↗") { open(file) }.buttonStyle(.plain).help("打开差异窗口").disabled(!model.isConnected)
        }
        .font(.system(size: 11.5)).padding(.leading, 12 + indent(depth)).padding(.trailing, 12).padding(.vertical, 6)
        .background(selected.contains(file) ? Theme.accentSoft : .clear).contentShape(Rectangle())
        .help(entry.path + " · " + kind.title)
        .onTapGesture(count: 2) { open(file) }
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.git.select(file, projectId: model.gitScope(project.id).key, additive: flags.contains(.command),
                             rangeFrom: flags.contains(.shift) ? anchor : nil, order: order)
            if !flags.contains(.shift) { anchor = file }
            focused = true
        }
        .background(GitVisibility(coordinator: controller?.gitRefresh, project: project.id, file: file))
        .contextMenu {
            Button("查看差异") { open(file) }
            Button(staged ? "取消暂存" : "暂存") { stage([file], !staged) }.disabled(disabled)
        }
    }

    private func indent(_ depth: Int) -> CGFloat { CGFloat(min(depth, 10)) * 12 }
    private func sectionKey(_ group: GitGroup) -> String { model.gitScope(project.id).key + ":" + group.id }
    private func stage(_ files: [GitFileKey], _ staged: Bool) {
        let scope = model.gitScope(project.id)
        Task { await model.stageGit(project.id, files: files, staged: staged, scope: scope) }
    }
}

private extension GitChangeKind {
    var color: Color {
        switch self {
        case .modified: Color(nsColor: .systemBlue)
        case .added, .copied: Theme.green
        case .deleted, .conflicted: Theme.red
        case .renamed, .typechange: Theme.purple
        case .untracked: Theme.amber
        }
    }
    var symbol: String {
        switch self {
        case .modified: "pencil"
        case .added: "plus"
        case .deleted: "minus"
        case .renamed: "arrow.right"
        case .copied: "doc.on.doc"
        case .typechange: "arrow.triangle.2.circlepath"
        case .untracked: "questionmark"
        case .conflicted: "exclamationmark.triangle"
        }
    }
}
