import Foundation

// MARK: - Open string enums

/// A string enum from the contract that must survive values added by a newer daemon.
///
/// Every conforming enum has its known cases plus `case other(String)`. Decoding an unknown
/// value yields `.other(raw)` instead of failing, and encoding writes the raw value back.
public protocol OpenEnum: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
where RawValue == String {
    /// All known cases (everything except `.other`).
    static var known: [Self] { get }
    static func other(_ raw: String) -> Self
}

extension OpenEnum {
    /// Non-failable: unknown values become `.other(raw)`.
    public init(raw: String) {
        self = Self.known.first { $0.rawValue == raw } ?? Self.other(raw)
    }

    /// Never returns nil; prefer `init(raw:)`.
    public init?(rawValue: String) {
        self.init(raw: rawValue)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(raw: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// False for `.other(_)`.
    public var isKnown: Bool { Self.known.contains(self) }

    public var description: String { rawValue }
}

// MARK: - Arbitrary JSON

/// Untyped JSON, used for `ApiError.details` and `ConfigDiffEntry` (`unknown` in the contract).
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var intValue: Int? {
        if case .number(let n) = self, n.rounded() == n, abs(n) < 9.0e15 { return Int(n) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Re-decode this value as a typed contract structure (e.g. `details.issues` → `[ValidationIssue]`).
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try ContractCoding.decoder().decode(T.self, from: data)
    }
}

// MARK: - Coders and timestamps

public enum ContractCoding {
    /// Contract types keep timestamps as ISO strings (lossless), so default strategies suffice.
    public static func decoder() -> JSONDecoder { JSONDecoder() }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

/// `Timestamp` in the contract: ISO-8601 UTC with milliseconds, kept as the wire string.
public typealias Timestamp = String
public typealias ProjectID = String
public typealias ServiceID = String
public typealias RunID = String
public typealias OperationID = String

public enum Timestamps {
    #if DEBUG
    /// Task-scoped test probe; release builds incur no instrumentation cost.
    @TaskLocal static var didParse: (@Sendable (Timestamp) -> Void)?
    #endif
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()
    // Parse only on first use, not during JSON decoding. NSCache lookups are thread-safe;
    // hits never acquire the formatter lock. Bound storage even for long-running log views.
    nonisolated(unsafe) private static let dates: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>(); cache.countLimit = 16_384; return cache
    }()
    nonisolated(unsafe) private static let invalid: NSCache<NSString, NSNull> = {
        let cache = NSCache<NSString, NSNull>(); cache.countLimit = 256; return cache
    }()

    public static func date(_ ts: Timestamp?) -> Date? {
        guard let ts else { return nil }
        let key = ts as NSString
        if let value = dates.object(forKey: key) { return value as Date }
        if invalid.object(forKey: key) != nil { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let value = dates.object(forKey: key) { return value as Date }
        #if DEBUG
        didParse?(ts)
        #endif
        let value = fractional.date(from: ts) ?? plain.date(from: ts)
        if let value { dates.setObject(value as NSDate, forKey: key) }
        else { invalid.setObject(NSNull(), forKey: key) }
        return value
    }

    public static func string(_ date: Date) -> Timestamp {
        lock.lock()
        defer { lock.unlock() }
        return fractional.string(from: date)
    }
}
