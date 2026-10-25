import Foundation

/// The next instant a time-dependent string changes, using the existing Format precision.
/// This has no timer or UI dependency; a completed/frozen label supplies no refresh rules.
public enum TextRefresh: Equatable, Sendable {
    case seconds
    case once(at: Date)
    case duration(since: Date)
    case ago(since: Date, quietAfter: TimeInterval? = nil)
    case days([Date])
    case countdown(until: Date)

    public func next(after now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .once(let date):
            return date > now ? date : nil
        case .seconds:
            return Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 1)
        case .duration(let start):
            let age = max(0, now.timeIntervalSince(start))
            let step: Double = age < 3600 ? 1 : age < 86400 ? 60 : 3600
            return start.addingTimeInterval((floor(age / step) + 1) * step)
        case .ago(let start, let quietAfter):
            let age = now.timeIntervalSince(start)
            if let quietAfter, age <= quietAfter { return start.addingTimeInterval(quietAfter + 0.001) }
            // Format.ago rounds seconds before selecting its unit.
            let rounded = max(0, floor(age + 0.5))
            let step: Double = rounded < 60 ? 1 : rounded < 3600 ? 60 : rounded < 86400 ? 3600 : 86400
            return start.addingTimeInterval((floor(rounded / step) + 1) * step - 0.5)
        case .days(let dates):
            // Today -> yesterday -> month/day, including calendar/DST boundaries.
            return dates.flatMap { date -> [Date] in
                let day = calendar.startOfDay(for: date)
                return (0...2).compactMap { calendar.date(byAdding: .day, value: $0, to: day) }
            }.filter { $0 > now }.min()
        case .countdown(let end):
            guard end > now else { return nil }
            return end.addingTimeInterval(-max(0, ceil(end.timeIntervalSince(now)) - 1))
        }
    }

    /// Coalesce clocks on wall seconds. Never refresh before the string can change.
    public static func alignedNext(_ rules: [TextRefresh], after now: Date) -> Date? {
        rules.compactMap { $0.next(after: now) }.min().map {
            Date(timeIntervalSince1970: ceil($0.timeIntervalSince1970))
        }
    }
}
