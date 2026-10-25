import AppKit
import DevPanelKit
import SwiftUI

struct GitTab: View {
    let model: AppModel
    let project: ProjectView
    @Environment(AppController.self) private var controller: AppController?
    @Environment(EditorPresenter.self) private var editor: EditorPresenter?
    @State private var stashScope: GitScope?
    @State private var showStashes = true
    @State private var showOutput = true
    @FocusState private var messageFocused: Bool
    private var status: GitStatus? { model.git.statuses[model.gitScope(project.id).key] }
    private var selected: Set<GitFileKey> { model.git.selections[model.gitScope(project.id).key, default: []] }
    private var disabled: Bool { !model.isConnected || model.git.busy.contains(model.gitScope(project.id).key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            repositoryPicker
            branch
            if let failure = model.git.failures[model.gitScope(project.id).key] {
                HStack(alignment: .top) {
                    Text(failure.title).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(); Button("关闭") { model.git.failures[model.gitScope(project.id).key] = nil }
                }.font(.system(size: 11)).foregroundStyle(Theme.red).padding(10).background(Theme.red.opacity(0.08))
            }
            if project.repositories?.isEmpty == true {
                ContentUnavailableView { Label("尚未登记 Git 仓库", systemImage: "point.3.connected.trianglepath.dotted") } description: { Text("编辑项目，填写各仓库相对项目根目录的路径。") } actions: { Button("编辑项目…") { editor?.edit(project.id) } }
            } else if let status, status.repo == nil {
                ContentUnavailableView("此项目不在 Git 仓库中", systemImage: "point.3.connected.trianglepath.dotted", description: Text("在终端中初始化仓库后刷新。"))
            } else if status == nil {
                VStack { Spacer(); if model.git.failures[model.gitScope(project.id).key] == nil { ProgressView("读取仓库…") }; Spacer() }.frame(maxWidth: .infinity)
            } else {
                GitChangesView(model: model, project: project, open: open)
                if status?.truncated == true { Text("改动文件过多，列表已截断").font(.caption).foregroundStyle(Theme.amber).padding(8) }
                if !selected.isEmpty {
                    HStack {
                        Text("已选 \(selected.count) 项").foregroundStyle(Theme.text3)
                        Spacer()
                        Button("暂存所选") { stage(Array(selected), true) }
                        Button("取消暂存所选") { stage(Array(selected.filter(\.staged)), false) }.disabled(!selected.contains { $0.staged })
                    }.font(.system(size: 11)).padding(8).disabled(disabled)
                }
                stashes
                commit
            }
            if let output = model.git.output[model.gitScope(project.id).key], !output.isEmpty {
                DisclosureGroup("Git 输出", isExpanded: $showOutput) {
                    ScrollView { Text(output).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                }.font(.system(size: 11)).padding(10)
            }
        }
        .background(GitVisibility(coordinator: controller?.gitRefresh, project: project.id, page: true))
        .task(id: model.gitScope(project.id).key + String(project.revision)) { if project.repositories?.isEmpty != true { await model.refreshGit(project.id) } }
        .sheet(item: $stashScope) { scope in GitStashSheet(model: model, projectId: project.id, scope: scope) }
        .alert("提交可能含密钥的文件？", isPresented: Binding(get: { model.git.confirmation?.projectId == project.id }, set: { if !$0 { model.git.confirmation = nil } })) {
            Button("取消", role: .cancel) { model.git.confirmation = nil }
            Button("仍然提交") { if let confirmation = model.git.confirmation { model.git.confirmation = nil; Task { await model.commitGit(project.id, request: confirmation.request, scope: confirmation.scope) } } }
        } message: { Text((model.git.confirmation?.sensitivePaths.joined(separator: "\n") ?? "") + "\n这些文件名可能包含密钥，请先检查差异。") }
    }
    @ViewBuilder private var repositoryPicker: some View {
        if let targets = project.repositories, !targets.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if model.selection != nil, let target = targets.first {
                    Text(target.name).font(.system(size: 12, weight: .medium))
                } else {
                Picker("仓库", selection: Binding(get: { model.gitScope(project.id).repositoryId ?? "" }, set: { model.git.repositorySelections[project.id] = $0 })) {
                    ForEach(targets) { Text($0.name).tag($0.id) }
                }
                }
                if let target = targets.first(where: { $0.id == model.gitScope(project.id).repositoryId }) {
                    Text(target.path).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.text3).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Theme.bar)
            Divider()
        }
    }
    private var branch: some View {
        HStack {
            if let repo = status?.repo {
                VStack(alignment: .leading, spacing: 3) {
                    Text("⎇ \(repo.displayBranch)").font(.system(size: 12, weight: .semibold))
                    if let upstream = repo.upstream { Text("\(upstream) · 领先 \(repo.ahead) · 落后 \(repo.behind)").font(.system(size: 10.5)).foregroundStyle(Theme.text3) }
                }
            } else { Text("Git").font(.system(size: 12, weight: .semibold)) }
            Spacer()
            if model.git.loading.contains(model.gitScope(project.id).key) { ProgressView().controlSize(.mini) }
            Button("刷新") { Task { await model.refreshGit(project.id); await model.refreshGitCounts(project.id, files: selected) } }.disabled(disabled)
        }.padding(12)
    }
    @ViewBuilder private var stashes: some View {
        let list = model.git.stashes[model.gitScope(project.id).key, default: []]
        if !list.isEmpty {
            Divider()
            DisclosureGroup("储藏（\(list.count)）", isExpanded: $showStashes) {
                ScrollView { VStack(spacing: 8) {
                    ForEach(list) { stash in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stash.message).lineLimit(1)
                                Text("\(stash.ref) · \(stash.branch ?? "—") · \(Timestamps.date(stash.createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? stash.createdAt)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.text3).lineLimit(1)
                            }
                            Spacer()
                            Menu("恢复") {
                                Button("恢复并移除（pop）") { apply(stash.ref, drop: true) }
                                Button("恢复并保留（apply）") { apply(stash.ref, drop: false) }
                            }.menuStyle(.borderlessButton).fixedSize().disabled(disabled)
                        }
                    }
                } }.frame(maxHeight: 95)
            }.font(.system(size: 11)).padding(10)
        }
    }
    private var commit: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: Binding(get: { model.git.messages[model.gitScope(project.id).key, default: ""] }, set: { model.git.messages[model.gitScope(project.id).key] = $0 }))
                .font(.system(size: 12)).scrollContentBackground(.hidden).padding(5).frame(height: 62).background(Theme.card, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                .overlay(alignment: .topLeading) { if model.git.messages[model.gitScope(project.id).key, default: ""].isEmpty { Text("提交信息").font(.system(size: 12)).foregroundStyle(Theme.text3).padding(10).allowsHitTesting(false) } }
                .focused($messageFocused).disabled(disabled)
                .onKeyPress(keys: [.return], phases: .down) { press in guard messageFocused, press.modifiers.contains(.command), !disabled else { return .ignored }; model.requestGitCommit(project.id); return .handled }
            HStack {
                Toggle("修改上一次提交", isOn: Binding(get: { model.git.amend[model.gitScope(project.id).key, default: false] }, set: { model.git.amend[model.gitScope(project.id).key] = $0 })).toggleStyle(.checkbox).disabled(status?.repo?.headSha == nil)
                Spacer()
                Button("储藏…") { stashScope = model.gitScope(project.id) }.disabled(status?.entries.isEmpty != false)
                Button(model.git.busy.contains(model.gitScope(project.id).key) ? "处理中…" : "提交 \(status?.entries.filter { $0.index != nil && !$0.conflicted }.count ?? 0) 个文件") { model.requestGitCommit(project.id) }
                    .buttonStyle(.borderedProminent).disabled(model.git.messages[model.gitScope(project.id).key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status?.entries.contains(where: \.conflicted) == true || (status?.entries.contains { $0.index != nil } != true && model.git.amend[model.gitScope(project.id).key] != true))
            }.font(.system(size: 11)).disabled(disabled)
        }.padding(12).background(Theme.bar)
    }
    private func stage(_ files: [GitFileKey], _ staged: Bool) {
        let scope = model.gitScope(project.id)
        Task { await model.stageGit(project.id, files: files, staged: staged, scope: scope) }
    }
    private func apply(_ ref: String, drop: Bool) {
        let scope = model.gitScope(project.id)
        Task { await model.applyGitStash(project.id, ref: ref, drop: drop, scope: scope) }
    }
    private func open(_ file: GitFileKey) { guard model.isConnected else { return }; controller?.gitWindows.open(project: project, file: file) }
}

private struct GitStashSheet: View {
    let model: AppModel
    let projectId: ProjectID
    let scope: GitScope
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUntracked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("储藏工作区改动").font(.headline)
            TextField("说明（可选）", text: $message)
            Toggle("包含未跟踪文件", isOn: $includeUntracked)
            Text("已暂存和未暂存的改动将保存到储藏，工作区恢复到 HEAD。忽略文件不会加入储藏。").font(.caption).foregroundStyle(Theme.text3)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("储藏") { Task { await model.stashGit(projectId, message: message, includeUntracked: includeUntracked, scope: scope); if model.git.failures[scope.key] == nil { dismiss() } } }.disabled(!model.isConnected || model.git.busy.contains(scope.key)) }
            if let failure = model.git.failures[scope.key] { Text(failure.title).foregroundStyle(Theme.red).font(.caption) }
        }.padding(20).frame(width: 440)
    }
}
