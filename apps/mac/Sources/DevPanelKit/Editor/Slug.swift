import Foundation

/// Service IDs (`/^[a-z][a-z0-9-]{0,31}$/`) derived from a service name.
public enum Slug {
    /// Common Chinese words in service names → English, so "后端" becomes `backend`.
    static let words: [(String, String)] = [
        ("数据库", "db"), ("后端", "backend"), ("前端", "frontend"), ("接口", "api"), ("服务", "service"),
        ("文档", "docs"), ("管理", "admin"), ("网关", "gateway"), ("任务", "worker"), ("队列", "queue"),
        ("缓存", "cache"), ("网站", "web"), ("定时", "cron"),
    ]

    public static func isValidServiceID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard let first = scalars.first, scalars.count <= 32, ("a"..."z").contains(first) else { return false }
        return scalars.dropFirst().allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// Lower-case slug for `name`, unique among `taken` (`-2`, `-3`, … appended).
    public static func make(_ name: String, taken: some Collection<String>) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for (zh, en) in words { s = s.replacingOccurrences(of: zh, with: " \(en) ") }
        var out = ""
        var lastDash = false
        for scalar in s.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        // Must start with a letter: drop leading digits and dashes.
        while let f = out.first, !("a"..."z").contains(f) { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { out = "service" }
        if out.count > 28 {
            out = String(out.prefix(28))
            while out.hasSuffix("-") { out.removeLast() }
        }
        let takenSet = Set(taken)
        var candidate = out
        var n = 2
        while takenSet.contains(candidate) {
            candidate = "\(out)-\(n)"
            n += 1
        }
        return candidate
    }
}
