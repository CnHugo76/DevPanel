import Foundation

// Option chips in the project card (ui-design v2 §5.1): `✦ 后端配置 dev ▾`.

public struct ParamChip: Sendable, Equatable, Identifiable {
    public var key: String
    public var label: String
    /// "dev", "仅本机" (enum choice label), "8081", "开", "••••", "未设置".
    public var value: String
    /// ✦: the value was last set by an agent (a value the user changed shows no ✦).
    public var byAgent: Bool
    public var secret: Bool
    /// The value changed but a service that references it still runs with the old value:
    /// dashed border + amber dot, "已修改，下次启动生效".
    public var pending: Bool
    public var help: String

    public var id: String { key }
}

extension ParamConfig {
    /// What the chip shows. Secrets are never shown.
    public var displayValue: String {
        if isSecret { return "••••" }
        guard let value else { return "未设置" }
        switch value {
        case .bool(let b): return b ? "开" : "关"
        case .string(let s):
            if type == .enum, let label = choices?.first(where: { $0.value == s })?.label, !label.isEmpty {
                return label
            }
            return s.isEmpty ? "（空）" : s
        case .number: return value.description
        }
    }

    /// Services of `project` that reference this param (`"*"` = project env → every service).
    public func referencingServices(in project: ProjectView) -> [ServiceID] {
        let refs = usedBy ?? []
        if refs.contains(where: \.isProjectLevel) { return project.services.map(\.id) }
        let ids = Set(refs.map(\.serviceId))
        return project.services.map(\.id).filter(ids.contains)
    }

    /// Compare actual values of current runs. Missing details / masked secrets fall back to
    /// the effective-config flag and value timestamp; overridden project env refs are excluded.
    public func isPending(in project: ProjectView, details: [RunID: RunDetail] = [:], serviceId: ServiceID? = nil) -> Bool {
        let changedAt = Timestamps.date(valueUpdatedAt)
        return referencingServices(in: project).contains { id in
            if let serviceId, id != serviceId { return false }
            guard let s = project.service(id), let run = s.currentRun else { return false }
            if !isSecret, let detail = details[run.id] {
                guard let actual = detail.params[key] else { return false }
                if case .value(let actualValue) = actual { return actualValue != value }
            }
            guard s.configChangedSinceStart,
                  let started = Timestamps.date(s.currentRun?.startedAt) else { return false }
            guard let changedAt else { return true }
            return changedAt > started
        }
    }
}

public enum ParamChips {
    /// Group by contract references, never by label guesses. Keep registration order.
    public static func groups(_ params: [ParamConfig], project: ProjectView, details: [RunID: RunDetail] = [:]) -> [ParamChipGroup] {
        let chips = make(params, project: project, details: details)
        var buckets: [String: [ParamChip]] = [:]
        for (param, chip) in zip(params, chips) {
            let refs = param.usedBy ?? []
            let services = Set(refs.map(\.serviceId))
            let owner = services.count == 1 ? project.services.first { services.contains($0.id) } : nil
            let id = refs.isEmpty ? "unused" : owner.map { "service:\($0.id)" } ?? "shared"
            var displayed = chip
            if let owner { displayed.label = compactLabel(chip.label, serviceName: owner.name) }
            buckets[id, default: []].append(displayed)
        }
        var groups = project.services.compactMap { service -> ParamChipGroup? in
            let id = "service:\(service.id)"
            guard let chips = buckets[id] else { return nil }
            return ParamChipGroup(id: id, title: service.name, serviceId: service.id, chips: chips)
        }
        for (id, title) in [("shared", "共用"), ("unused", "未引用")] {
            if let chips = buckets[id] {
                groups.append(ParamChipGroup(id: id, title: title, serviceId: nil, chips: chips))
            }
        }
        return groups
    }

    private static func compactLabel(_ label: String, serviceName: String) -> String {
        guard !serviceName.isEmpty, label.hasPrefix(serviceName) else { return label }
        let suffix = String(label.dropFirst(serviceName.count))
        // A Latin service name must end at a word boundary (API must not shorten APIKey).
        if let last = serviceName.last, last.isASCII, last.isLetter || last.isNumber,
           let next = suffix.first, next.isASCII, next.isLetter || next.isNumber { return label }
        let shortened = suffix.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "·:：-–—")))
        return shortened.isEmpty ? label : shortened
    }

    public static func make(_ params: [ParamConfig], project: ProjectView, details: [RunID: RunDetail] = [:]) -> [ParamChip] {
        params.map { p in
            let pending = p.isPending(in: project, details: details)
            var help: [String] = []
            if pending { help.append("已修改，下次启动生效") }
            help.append("\(p.label)：\(p.displayValue)")
            help.append("${\(p.key)}" + (p.setBy == .agent ? " · 由 AI 设置" : p.setBy == .user ? " · 你设置的值" : ""))
            if let d = p.description, !d.isEmpty { help.append(d) }
            return ParamChip(
                key: p.key, label: p.label, value: p.displayValue, byAgent: p.setBy == .agent,
                secret: p.isSecret, pending: pending, help: help.joined(separator: "\n"))
        }
    }

    /// Whether `serviceId` is affected by a pending param (picks "选项已修改" for its note).
    public static func serviceHasPendingParam(
        _ serviceId: ServiceID, params: [ParamConfig], project: ProjectView, details: [RunID: RunDetail] = [:]
    ) -> Bool {
        params.contains { $0.isPending(in: project, details: details, serviceId: serviceId) }
    }
}

public struct ParamChipGroup: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var serviceId: ServiceID?
    public var chips: [ParamChip]
}
