import Foundation

/// Shell-style argv handling for the single-line command field (ui-design §6).
///
/// Splitting follows a POSIX `sh` subset: blanks separate words; `'…'` is literal; inside
/// `"…"` only `\"` `\\` `\$` `` \` `` and a backslash-newline are escapes; outside quotes a
/// backslash escapes the next character. No expansion, globbing or operators: `&`, `|`, `;`
/// are ordinary characters of a word (the daemon receives argv, never a shell string).
public enum ShellWords {
    public enum SplitError: Equatable, Sendable, CustomStringConvertible {
        case unclosedDoubleQuote
        case unclosedSingleQuote

        public var description: String {
            switch self {
            case .unclosedDoubleQuote: "双引号未闭合"
            case .unclosedSingleQuote: "单引号未闭合"
            }
        }
    }

    public struct SplitResult: Equatable, Sendable {
        public var argv: [String]
        public var error: SplitError?
    }

    public static func split(_ input: String) -> SplitResult {
        var argv: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            defer { i += 1 }
            if quote == "'" {
                if ch == "'" { quote = nil } else { current.append(ch) }
                continue
            }
            if quote == "\"" {
                if ch == "\"" {
                    quote = nil
                } else if ch == "\\", i + 1 < chars.count, "\"\\$`\n".contains(chars[i + 1]) {
                    i += 1
                    if chars[i] != "\n" { current.append(chars[i]) }
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                inWord = true
                continue
            }
            if ch == "\\" {
                if i + 1 < chars.count {
                    i += 1
                    if chars[i] != "\n" {
                        current.append(chars[i])
                        inWord = true
                    }
                } else {
                    current.append("\\")
                    inWord = true
                }
                continue
            }
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                if inWord {
                    argv.append(current)
                    current = ""
                    inWord = false
                }
                continue
            }
            current.append(ch)
            inWord = true
        }
        if let quote {
            if inWord { argv.append(current) }
            return SplitResult(argv: argv, error: quote == "\"" ? .unclosedDoubleQuote : .unclosedSingleQuote)
        }
        if inWord { argv.append(current) }
        return SplitResult(argv: argv, error: nil)
    }

    /// Characters that never need quoting.
    static func isSafe(_ c: Character) -> Bool {
        guard let a = c.asciiValue else { return false }
        switch a {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            return "_-+=.,/:@%^".contains(c)
        }
    }

    /// Quotes one argument so that `split(join(x)).argv == x`.
    public static func quote(_ arg: String) -> String {
        if arg.isEmpty { return "''" }
        if arg.allSatisfy(isSafe) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
    }

    // MARK: Shell form

    public static let defaultShell = "/bin/zsh"
    public static let defaultShellFlag = "-lc"
    static let shells: Set<String> = ["/bin/zsh", "/bin/bash", "/bin/sh", "zsh", "bash", "sh"]

    public struct ShellForm: Equatable, Sendable {
        public var shell: String
        public var flag: String
        public var script: String
    }

    /// `["/bin/zsh", "-lc", "<script>"]` (or bash / sh, `-c`) → its parts; otherwise nil.
    public static func shellForm(_ command: [String]) -> ShellForm? {
        guard command.count == 3, shells.contains(command[0]), command[1] == "-lc" || command[1] == "-c" else {
            return nil
        }
        return ShellForm(shell: command[0], flag: command[1], script: command[2])
    }

    // MARK: Background detection

    /// The construct that detaches / backgrounds the process (`&`, `nohup`, `setsid`, `disown`,
    /// `daemonize`, `docker … -d`), or nil. Scans the raw text with quote awareness, so it works
    /// for both a plain command line and a shell script. Redirections such as `2>&1`, `&>file`,
    /// `>&2` and the operators `&&` / `||` do not count.
    public static func backgroundHint(_ text: String) -> String? {
        struct Token { var text: String; var isOperator: Bool }
        var tokens: [Token] = []
        var current = ""
        var quote: Character?
        let chars = Array(text)
        func push() {
            if !current.isEmpty { tokens.append(Token(text: current, isOperator: false)) }
            current = ""
        }
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                i += 1
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                i += 1
                continue
            }
            if ch == "\\" {
                if i + 1 < chars.count { current.append(chars[i + 1]) }
                i += 2
                continue
            }
            if ch.isWhitespace {
                push()
                i += 1
                continue
            }
            if ch == "&" || ch == "|" || ch == ";" {
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if (ch == "&" && next == "&") || (ch == "|" && next == "|") {
                    push()
                    tokens.append(Token(text: String([ch, ch]), isOperator: true))
                    i += 2
                    continue
                }
                let prev: Character? = i > 0 ? chars[i - 1] : nil
                if ch == "&", prev == ">" || prev == "<" || next == ">" {
                    current.append(ch)
                    i += 1
                    continue
                }
                push()
                tokens.append(Token(text: String(ch), isOperator: true))
                i += 1
                continue
            }
            current.append(ch)
            i += 1
        }
        push()

        if tokens.contains(where: { $0.isOperator && $0.text == "&" }) { return "&" }
        for (i, token) in tokens.enumerated() where !token.isOperator {
            let isCommandWord = i == 0 || tokens[i - 1].isOperator
            guard isCommandWord else { continue }
            let name = (token.text as NSString).lastPathComponent
            if ["nohup", "disown", "setsid", "daemonize"].contains(name) { return name }
            if ["docker", "docker-compose", "podman"].contains(name) {
                var j = i + 1
                while j < tokens.count, !tokens[j].isOperator {
                    let r = tokens[j].text
                    if r == "--detach" { return "-d" }
                    if r.count >= 2, r.hasPrefix("-"), !r.hasPrefix("--"),
                       r.dropFirst().allSatisfy({ "dit".contains($0) }), r.contains("d") {
                        return "-d"
                    }
                    j += 1
                }
            }
        }
        return nil
    }
}
