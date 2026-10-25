import Foundation

/// The command preview under the command field: each argv element with `${key}` replaced by the
/// current option value (contract §3.1), split into segments so the view can color them.
///
/// - `$${` is a literal `${` (shown as `${`).
/// - Only `${` + valid key + `}` is a placeholder; `${a:-b}`, `${}` and an unclosed `${` stay literal.
/// - A valid key that names no option is `unknown` (the daemon rejects it with PARAM_UNKNOWN).
/// - Secret options show `••••`.
/// - In the script argument of `sh|bash|zsh -c` / `-…c`, values are single-quoted like the daemon does.
public struct CommandPreview: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case text
            /// From option `key`.
            case value(key: String)
            case secret(key: String)
            /// `${key}` with no such option; `text` is the placeholder as written.
            case unknown(key: String)
            /// `$${` written as a literal `${`.
            case escaped
        }

        public var text: String
        public var kind: Kind
    }

    public struct Arg: Equatable, Sendable {
        public var segments: [Segment]
        public var text: String { segments.map(\.text).joined() }
    }

    public var args: [Arg]
    /// Index of the shell script argument (values quoted), if any.
    public var scriptIndex: Int?

    /// Whether anything was substituted or unescaped (otherwise the preview equals the argv).
    public var changesAnything: Bool {
        args.contains { $0.segments.contains { $0.kind != .text } }
    }

    /// Unknown option keys, in order of first appearance.
    public var unknownKeys: [String] {
        var seen: [String] = []
        for a in args {
            for s in a.segments {
                if case .unknown(let k) = s.kind, !seen.contains(k) { seen.append(k) }
            }
        }
        return seen
    }

    /// The argv as it would run, one string per element.
    public var argv: [String] { args.map(\.text) }

    public static func make(_ argv: [String], params: [ParamConfig]) -> CommandPreview {
        let byKey = Dictionary(params.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let script = scriptIndex(argv)
        let args = argv.enumerated().map { i, arg in
            Arg(segments: segments(arg, params: byKey, quote: i == script))
        }
        return CommandPreview(args: args, scriptIndex: script)
    }

    /// Unknown keys referenced in a (non-secret) env value.
    public static func unknownKeys(in value: String, params: [ParamConfig]) -> [String] {
        let byKey = Dictionary(params.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for s in segments(value, params: byKey, quote: false) {
            if case .unknown(let k) = s.kind, !out.contains(k) { out.append(k) }
        }
        return out
    }

    /// Contract §3.1: `command[0]` named sh/bash/zsh, followed by `-c` or a short option group
    /// ending in `c` (e.g. `-lc`): the next argv element is the script.
    static func scriptIndex(_ argv: [String]) -> Int? {
        guard let first = argv.first, ["sh", "bash", "zsh"].contains((first as NSString).lastPathComponent) else {
            return nil
        }
        for i in argv.indices.dropFirst() {
            let a = argv[i]
            if a == "-c" || (a.count >= 2 && a.hasPrefix("-") && !a.hasPrefix("--") && a.hasSuffix("c")) {
                return i + 1 < argv.count ? i + 1 : nil
            }
        }
        return nil
    }

    static func segments(_ s: String, params: [String: ParamConfig], quote: Bool) -> [Segment] {
        var out: [Segment] = []
        var text = ""
        func flush() {
            if !text.isEmpty { out.append(Segment(text: text, kind: .text)) }
            text = ""
        }
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "$", i + 2 < chars.count, chars[i + 1] == "$", chars[i + 2] == "{" {
                flush()
                out.append(Segment(text: "${", kind: .escaped))
                i += 3
                continue
            }
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "{",
               let close = chars[(i + 2)...].firstIndex(of: "}") {
                let key = String(chars[(i + 2)..<close])
                if CommandText.isKey(key) {
                    flush()
                    if let p = params[key] {
                        let raw = p.isSecret ? "••••" : (p.value?.description ?? "")
                        let shown = quote ? CommandText.shellQuote(raw) : raw
                        out.append(Segment(text: shown, kind: p.isSecret ? .secret(key: key) : .value(key: key)))
                    } else {
                        out.append(Segment(text: String(chars[i...close]), kind: .unknown(key: key)))
                    }
                    i = close + 1
                    continue
                }
            }
            text.append(chars[i])
            i += 1
        }
        flush()
        return out
    }
}
