import Foundation

/// Optional display grouping; never changes root, project identity, or process ownership.
public struct ProjectInstance: Codable, Hashable, Sendable {
    public var group: String
    public var name: String
    public init(group: String, name: String) { self.group = group; self.name = name }
    public var displayText: String { group + " / " + name }
    public static func isValidLabel(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.unicodeScalars.count <= 80
            && !value.unicodeScalars.contains {
                [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
            }
    }
}
