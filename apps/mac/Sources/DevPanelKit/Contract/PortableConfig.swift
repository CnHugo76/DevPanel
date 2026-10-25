import Foundation

public struct PortableConfigInput: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case secret, path }
    public var id: String
    public var target: String
    public var kind: Kind
    public var label: String
    public var valueType: ParamType?
}

/// v1.5-B. `project` deliberately has no root; local inputs live in a separate file.
public struct PortableProjectConfig: Codable, Hashable, Sendable {
    public var format: String
    public var version: Int
    public var project: JSONValue
    public var inputs: [PortableConfigInput]
}
