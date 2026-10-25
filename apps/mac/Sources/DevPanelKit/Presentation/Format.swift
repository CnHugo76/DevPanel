import Foundation

/// Number / time / path formatting shared by every view (ported from apps/ui/src/lib/format.ts,
/// ui-design v1 §8: MiB / GiB with 1–2 decimals, durations `1h12m` / `3m05s`, local time).
public enum Format {
    private static let KiB = 1024.0
    private static let MiB = KiB * 1024
    private static let GiB = MiB * 1024

    /// `512 B`, `12.5 KiB`, `196 MiB`, `12.3 MiB`, `1.12 GiB`.
    public static func bytes(_ n: Int) -> String {
        let v = Double(n)
        if v < KiB { return "\(n) B" }
        if v < MiB { return String(format: "%.1f KiB", v / KiB) }
        if v < GiB {
            let m = v / MiB
            if m >= 100 || m.rounded() == m { return "\(Int(m.rounded())) MiB" }
            return String(format: "%.1f MiB", m)
        }
        return String(format: "%.2f GiB", v / GiB)
    }

    /// `128.0%`. 100% = one logical CPU fully used; never capped.
    public static func cpu(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }

    /// `45s`, `3m05s`, `1h12m`, `2d3h`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let d = s / 86_400
        let h = (s % 86_400) / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h" + pad(m) + "m" }
        if m > 0 { return "\(m)m" + pad(sec) + "s" }
        return "\(sec)s"
    }

    /// `10:42:07` (local time).
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return "\(pad(c.hour ?? 0)):\(pad(c.minute ?? 0)):\(pad(c.second ?? 0))"
    }

    /// `10:42` today, `昨天 18:02`, otherwise `10/18 18:02`.
    public static func dayTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let hm = "\(pad(c.hour ?? 0)):\(pad(c.minute ?? 0))"
        if calendar.isDate(date, inSameDayAs: now) { return hm }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return "昨天 \(hm)"
        }
        return "\(c.month ?? 0)/\(c.day ?? 0) \(hm)"
    }

    /// `/Users/demo/Project/foo` → `~/Project/foo` (only for /Users/<name> and /home/<name>).
    public static func tildePath(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            guard let name = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first,
                  !name.isEmpty else { return path }
            return "~" + rest.dropFirst(name.count)
        }
        return path
    }

    /// Keeps the random tail of a ULID run ID: `r_01JC8ZB3P1XQ4K` → `r_P1XQ4K`.
    public static func shortRunId(_ id: RunID) -> String {
        let body = id.hasPrefix("r_") ? String(id.dropFirst(2)) : id
        return body.count > 6 ? "r_" + body.suffix(6) : id
    }

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}
