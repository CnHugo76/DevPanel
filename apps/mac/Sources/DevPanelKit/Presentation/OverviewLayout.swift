import Foundation

// Overview table geometry, search filter and process colors (ui-design v2 §2–§3).

public enum OverviewColumn: String, CaseIterable, Sendable {
    case service, command, status, ports, uptime, cpu, memory, actions

    public var title: String {
        switch self {
        case .service: "服务"
        case .command: "命令"
        case .status: "状态"
        case .ports: "端口"
        case .uptime: "运行时长"
        case .cpu: "CPU"
        case .memory: "内存"
        case .actions: "操作"
        }
    }

    /// Numbers are right-aligned.
    public var trailing: Bool {
        switch self {
        case .uptime, .cpu, .memory, .actions: true
        default: false
        }
    }
}

/// Fixed column widths for one table width; every card uses the same layout, so columns line
/// up across cards. Widths include the cell's horizontal padding.
public struct ColumnLayout: Sendable, Equatable {
    public let compact: Bool
    private let widths: [OverviewColumn: Double]

    /// Visible columns in display order.
    public var columns: [OverviewColumn] { OverviewColumn.allCases.filter { widths[$0] != nil } }

    /// nil = hidden in this mode.
    public func width(_ column: OverviewColumn) -> Double? { widths[column] }

    public var totalWidth: Double { widths.values.reduce(0, +) }

    public static let actionsWidth = 96.0
    static let minFlex = 80.0

    /// - Parameters:
    ///   - tableWidth: inner width of a service table.
    ///   - compact: the inspector is open: hide 命令 and 运行时长, keep CPU / 内存 whole.
    public static func make(tableWidth: Double, compact: Bool) -> ColumnLayout {
        let w = max(tableWidth, 0)
        var widths: [OverviewColumn: Double] = [:]
        let compact = compact || w < 800
        if compact {
            // Reserve readable numeric columns first. Ports yield before CPU or memory.
            widths[.cpu] = 80
            widths[.memory] = 116 // Includes an explicit RSS suffix on fallback samples.
            widths[.actions] = actionsWidth
            widths[.status] = w >= 540 ? 112 : 72
            if w >= 596 { widths[.ports] = min(100, w - 496) }
            let fixed = widths.values.reduce(0, +)
            widths[.service] = max(w - fixed, 92)
        } else {
            func pct(_ p: Double) -> Double { (w * p).rounded(.down) }
            widths[.service] = pct(0.16)
            widths[.status] = pct(0.15)
            widths[.ports] = pct(0.10)
            widths[.uptime] = pct(0.09)
            widths[.cpu] = max(pct(0.08), 80)
            widths[.memory] = max(pct(0.09), 116)
            widths[.actions] = actionsWidth
            let fixed = widths.values.reduce(0, +)
            widths[.command] = max(w - fixed, minFlex)
        }
        return ColumnLayout(compact: compact, widths: widths)
    }

    private init(compact: Bool, widths: [OverviewColumn: Double]) {
        self.compact = compact
        self.widths = widths
    }
}

// MARK: - Search

public struct FilteredProject: Sendable, Equatable, Identifiable {
    public var project: ProjectView
    /// Services to show, in config order.
    public var services: [ServiceView]
    public var id: ProjectID { project.id }
}

public enum OverviewFilter {
    /// Instance filters keep independent project identities and registration order.
    /// A matching project shows all its services; otherwise only matching services.
    public static func apply(_ projects: [ProjectView], query: String) -> [FilteredProject] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return projects.map { FilteredProject(project: $0, services: $0.services) } }
        let scoped = String(query.drop(while: { $0.isWhitespace }))
        for (prefix, value) in [("group:", { (p: ProjectView) in p.instance?.group }), ("instance:", { (p: ProjectView) in p.instance?.name })] {
            if scoped.lowercased().hasPrefix(prefix) {
                let expected = String(scoped.dropFirst(prefix.count))
                return projects.compactMap { p in
                    guard let actual = value(p), actual.compare(expected, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame else { return nil }
                    return FilteredProject(project: p, services: p.services)
                }
            }
        }
        func matches(_ s: String) -> Bool {
            s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
        return projects.compactMap { p in
            if [p.name, p.id, p.root, p.instance?.group ?? "", p.instance?.name ?? ""].contains(where: matches) {
                return FilteredProject(project: p, services: p.services)
            }
            let services = p.services.filter { matches($0.name) }
            return services.isEmpty ? nil : FilteredProject(project: p, services: services)
        }
    }
}

// MARK: - Process colors

/// Fixed 8-color palette, picked by the service's position in its project (config order).
/// The log view (F3) uses the same color for the same service.
public enum ProcessPalette {
    /// Blue, cyan and slate identities. Reserve green, red, amber and purple for status.
    public static let colors: [UInt32] = [
        0x428BC1, 0x7B8D9D, 0x349AB8, 0x5F7897, 0x73A6C7, 0x939DA8, 0x527C91, 0x648EAA,
    ]

    public static func index(of serviceId: ServiceID, in project: ProjectView) -> Int {
        let i = project.services.firstIndex { $0.id == serviceId } ?? 0
        return i % colors.count
    }

    public static func color(of serviceId: ServiceID, in project: ProjectView) -> UInt32 {
        colors[index(of: serviceId, in: project)]
    }
}

// MARK: - Commands

public enum CommandText {
    /// argv as one line for display; elements with spaces are quoted. Placeholders stay as is.
    public static func join(_ argv: [String]) -> String {
        argv.map { a in
            if a.isEmpty { return "''" }
            if a.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" || $0 == "'" }) {
                return "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return a
        }.joined(separator: " ")
    }
}

extension CommandText {
    /// Previews the argv the next start would run with the current param values (contract
    /// §3.1): `${key}` → value, `$${` → `${`, unknown keys and malformed placeholders stay
    /// literal. Secret params show as `••••`. Inside an `sh|bash|zsh -c` script, values are
    /// single-quoted like the daemon does.
    public static func substitute(_ argv: [String], params: [ParamConfig]) -> [String] {
        let values = Dictionary(params.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var scriptIndex: Int?
        if let first = argv.first, ["sh", "bash", "zsh"].contains((first as NSString).lastPathComponent) {
            for i in argv.indices.dropFirst() {
                let a = argv[i]
                if a == "-c" || (a.hasPrefix("-") && !a.hasPrefix("--") && a.hasSuffix("c")) {
                    scriptIndex = i + 1 < argv.count ? i + 1 : nil
                    break
                }
            }
        }
        return argv.enumerated().map { i, arg in
            replace(arg) { key in
                guard let p = values[key] else { return nil }
                let text = p.isSecret ? "••••" : (p.value?.description ?? "")
                return i == scriptIndex ? shellQuote(text) : text
            }
        }
    }

    /// Whether any element contains a well-formed placeholder.
    public static func hasPlaceholders(_ argv: [String]) -> Bool {
        argv.contains { arg in
            var found = false
            _ = replace(arg) { _ in found = true; return nil }
            return found
        }
    }

    static func replace(_ s: String, _ value: (String) -> String?) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "$", i + 2 < chars.count, chars[i + 1] == "$", chars[i + 2] == "{" {
                out += "${"
                i += 3
                continue
            }
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "{",
               let close = chars[(i + 2)...].firstIndex(of: "}") {
                let key = String(chars[(i + 2)..<close])
                if isKey(key) {
                    if let v = value(key) {
                        out += v
                    } else {
                        out += String(chars[i...close])
                    }
                    i = close + 1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// `/^[a-zA-Z][a-zA-Z0-9_]{0,31}$/`
    static func isKey(_ k: String) -> Bool {
        guard let first = k.unicodeScalars.first, k.unicodeScalars.count <= 32 else { return false }
        func letter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
        guard letter(first) else { return false }
        return k.unicodeScalars.dropFirst().allSatisfy { letter($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
