import DevPanelKit
import SwiftUI

struct ServiceLinkControl: View {
    let model: AppModel
    let ref: ServiceRef
    let serviceName: String
    @Environment(ServiceLinkPreferences.self) private var links
    @Environment(\.openURL) private var openURL
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            Text("快捷打开地址").foregroundStyle(Theme.text3)
            if let url = links.customURL(for: ref) {
                Button { openURL(url) } label: {
                    Text(url.absoluteString).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent2)
                .help(url.absoluteString)
                .accessibilityLabel("打开 \(url.absoluteString)")
            } else {
                Text("默认 localhost:<端口>").foregroundStyle(Theme.text3).lineLimit(1)
                    .help("点击端口旁的 ↗ 打开 http://localhost:<端口>")
            }
            Spacer(minLength: 0)
            Button("编辑…") { editing = true }
                .help("编辑 \(serviceName) 的快捷打开地址")
                .accessibilityLabel("编辑快捷打开地址")
        }
        .font(.system(size: 11))
        .sheet(isPresented: $editing) {
            ServiceLinkSheet(links: links, ref: ref, serviceName: serviceName, ports: model.shortcutPorts(ref))
        }
    }
}

struct ServiceLinkSheet: View {
    let links: ServiceLinkPreferences
    let ref: ServiceRef
    let serviceName: String
    @State private var ports: [Int]
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text: String
    @State private var localAddresses: [LocalNetworkAddress] = []

    init(links: ServiceLinkPreferences, ref: ServiceRef, serviceName: String, ports: [Int] = []) {
        self.links = links
        self.ref = ref
        self.serviceName = serviceName
        _ports = State(initialValue: ports)
        _text = State(initialValue: links.customURL(for: ref)?.absoluteString ?? ports.first.map { "http://localhost:\($0)/" } ?? "")
    }

    private var error: String? { ServiceShortcutAddress.validationMessage(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("快捷打开地址").font(.headline)
            Text(serviceName).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("选择主机").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    hostButton("localhost")
                    hostButton("127.0.0.1")
                    Menu("局域网地址") {
                        if localAddresses.isEmpty { Text("未检测到内网 IPv4 地址") }
                        ForEach(localAddresses) { entry in
                            Button(entry.address + " · " + entry.interface) { chooseHost(entry.address) }
                        }
                        Divider()
                        Button("刷新地址") { localAddresses = LocalNetworkAddress.detect() }
                    }
                    .help("选择这台 Mac 的内网地址，保留端口和路径")
                }
                if !localAddresses.isEmpty {
                    Text(localAddresses.map { $0.address + "（" + $0.interface + "）" }.joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !ports.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("端口").font(.callout).foregroundStyle(.secondary)
                            ForEach(ports.prefix(5), id: \.self) { port in portButton(port) }
                            if ports.count > 5 { portMenu }
                        }
                        portMenu
                    }
                } else {
                    Text("尚无已知端口，可在下方补充端口或完整地址。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("HTTP/HTTPS 地址")
                TextField("http://localhost:8080/", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .accessibilityLabel("快捷打开地址")
                    .onSubmit(save)
                if let error {
                    Text(error).font(.callout).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("选择主机或端口会保留已有的协议、路径和查询参数，也可直接修改完整地址。局域网地址来自本机网络接口，服务需允许局域网访问。留空保存可恢复各端口的默认地址。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("清空") { text = ""; focused = true }.disabled(text.isEmpty)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(error != nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { localAddresses = LocalNetworkAddress.detect() }
    }

    private func hostButton(_ host: String) -> some View {
        Button(host) { chooseHost(host) }
            .help("使用 \(host)，保留端口和路径")
    }

    private func chooseHost(_ host: String) {
        text = ServiceLinkSuggestions.address(text, host: host, defaultPort: ports.first)
    }

    private func portButton(_ port: Int) -> some View {
        Button(String(port)) { text = ServiceLinkSuggestions.address(text, port: port) }
    }

    private var portMenu: some View {
        Menu("选择端口") {
            ForEach(ports, id: \.self) { port in
                Button(String(port)) { text = ServiceLinkSuggestions.address(text, port: port) }
            }
        }
    }

    private func save() {
        guard links.save(text, for: ref) == nil else { return }
        dismiss()
    }
}

extension AppModel {
    func shortcutPorts(_ ref: ServiceRef) -> [Int] {
        ServiceLinkSuggestions.ports(listening: serviceStats(ref.projectId, ref.serviceId)?.listening,
                                     config: serviceConfig(ref.projectId, ref.serviceId), params: params(ref.projectId))
    }
}
