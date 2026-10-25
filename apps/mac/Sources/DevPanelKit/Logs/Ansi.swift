import Foundation

// Minimal ANSI handling for log lines (ui-design v1 §5.4), ported from apps/ui/src/lib/ansi.ts.
// Only SGR (`ESC [ … m`) is interpreted: colors (16 / 256 / truecolor), bold, dim, italic,
// underline, inverse, strikethrough, reset. Every other escape / control sequence (cursor moves,
// OSC titles and hyperlinks, DCS, C0 / C1 controls except TAB) is dropped. The result is plain
// text plus style runs; views render it as text, never as markup.

public enum AnsiColor: Hashable, Sendable {
    /// 0–15 are the theme's 16 colors; 16–255 the xterm cube and gray ramp.
    case palette(Int)
    case rgb(UInt8, UInt8, UInt8)

    /// sRGB of a 256-color index ≥ 16 (indices < 16 come from the theme palette).
    public static func xterm(_ n: Int) -> (UInt8, UInt8, UInt8) {
        if n < 232 {
            let i = max(n - 16, 0)
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return (levels[(i / 36) % 6], levels[(i / 6) % 6], levels[i % 6])
        }
        let g = UInt8(clamping: 8 + (n - 232) * 10)
        return (g, g, g)
    }
}

public struct AnsiStyle: Hashable, Sendable {
    public var foreground: AnsiColor?
    public var background: AnsiColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var strikethrough = false

    public init(
        foreground: AnsiColor? = nil, background: AnsiColor? = nil, bold: Bool = false, dim: Bool = false,
        italic: Bool = false, underline: Bool = false, inverse: Bool = false, strikethrough: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
        self.strikethrough = strikethrough
    }

    public static let plain = AnsiStyle()
    public var isPlain: Bool { self == .plain }
}

/// A styled stretch of `AnsiText.plain`, in UTF-16 units (what `NSString` / `NSRange` use).
public struct AnsiRun: Hashable, Sendable {
    public var location: Int
    public var length: Int
    public var style: AnsiStyle

    public init(location: Int, length: Int, style: AnsiStyle) {
        self.location = location
        self.length = length
        self.style = style
    }
}

public struct AnsiText: Hashable, Sendable {
    /// The text without any escape / control sequence (TAB kept).
    public var plain: String
    /// Non-plain styles only, ascending and non-overlapping.
    public var runs: [AnsiRun]

    public init(plain: String, runs: [AnsiRun] = []) {
        self.plain = plain
        self.runs = runs
    }
}

public enum Ansi {
    private static let esc: UInt16 = 0x1B
    private static let bel: UInt16 = 0x07

    /// Parses SGR styles and drops every other control sequence.
    public static func parse(_ input: String) -> AnsiText {
        guard needsParsing(input) else { return AnsiText(plain: input) }
        let u = Array(input.utf16)
        let n = u.count
        var out: [UInt16] = []
        out.reserveCapacity(n)
        var runs: [AnsiRun] = []
        var style = AnsiStyle.plain
        var runStart = 0

        func flush() {
            if !style.isPlain, out.count > runStart {
                runs.append(AnsiRun(location: runStart, length: out.count - runStart, style: style))
            }
            runStart = out.count
        }

        var i = 0
        while i < n {
            let c = u[i]
            if isPrintable(c) || c == 0x09 {
                out.append(c)
                i += 1
                continue
            }
            if c == esc {
                guard i + 1 < n else { i += 1; continue }
                let next = u[i + 1]
                switch next {
                case 0x5B:  // "[" CSI
                    var j = i + 2
                    while j < n, !(0x40...0x7E).contains(u[j]) { j += 1 }
                    if j >= n {
                        i = n  // unterminated CSI: drop the rest
                        continue
                    }
                    if u[j] == 0x6D {  // "m"
                        let params = u[(i + 2)..<j]
                        if params.allSatisfy({ (0x30...0x39).contains($0) || $0 == 0x3B || $0 == 0x3A }) {
                            let next = applySGR(style, String(decoding: params, as: UTF16.self))
                            if next != style {
                                flush()
                                style = next
                            }
                        }
                    }
                    i = j + 1
                case 0x5D, 0x50, 0x5E, 0x5F, 0x58:  // ] P ^ _ X: OSC / DCS / PM / APC / SOS
                    i = skipString(u, from: i + 2)
                case 0x28, 0x29, 0x2A, 0x2B, 0x2D, 0x2E, 0x2F, 0x23, 0x25:  // ( ) * + - . / # %
                    i += 3  // charset designation etc.
                default:
                    i += 2
                }
            } else if c == 0x9B {  // C1 CSI
                var j = i + 1
                while j < n, !(0x40...0x7E).contains(u[j]) { j += 1 }
                i = j + 1
            } else if c == 0x9D || c == 0x90 || c == 0x9E || c == 0x9F || c == 0x98 {  // C1 OSC / DCS / PM / APC / SOS
                i = skipString(u, from: i + 1)
            } else {
                i += 1  // other C0 / C1 controls (\r, \b, \n, …) are dropped
            }
        }
        flush()
        return AnsiText(plain: String(decoding: out, as: UTF16.self), runs: runs)
    }

    /// The text without escape / control sequences.
    public static func strip(_ input: String) -> String {
        needsParsing(input) ? parse(input).plain : input
    }

    /// Fast check: any C0 control other than TAB, DEL, or a C1 control (U+0080–U+009F).
    static func needsParsing(_ s: String) -> Bool {
        var prevC2 = false
        for b in s.utf8 {
            if b < 0x20 && b != 0x09 { return true }
            if b == 0x7F { return true }
            if prevC2 && (0x80...0x9F).contains(b) { return true }
            prevC2 = b == 0xC2
        }
        return false
    }

    @inline(__always)
    private static func isPrintable(_ c: UInt16) -> Bool {
        c >= 0x20 && c != 0x7F && !(0x80...0x9F).contains(c)
    }

    /// Index just past a string terminated by BEL or ESC \ (OSC / DCS / APC / PM / SOS).
    private static func skipString(_ u: [UInt16], from: Int) -> Int {
        var j = from
        while j < u.count {
            if u[j] == bel { return j + 1 }
            if u[j] == 0x9C { return j + 1 }  // C1 ST
            if u[j] == esc, j + 1 < u.count, u[j + 1] == 0x5C { return j + 2 }
            j += 1
        }
        return u.count
    }

    /// Applies an SGR parameter string ("1;32", "38;5;208", "38:2::10:20:30", "") to a style.
    public static func applySGR(_ previous: AnsiStyle, _ params: String) -> AnsiStyle {
        var s = previous
        let codes: [Int] = params.isEmpty
            ? [0]
            : params.split(separator: ";", omittingEmptySubsequences: false)
                .flatMap { $0.split(separator: ":", omittingEmptySubsequences: false) }
                .map { Int($0) ?? 0 }
        let colonForm = params.contains("::")
        var i = 0
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0: s = .plain
            case 1: s.bold = true
            case 2: s.dim = true
            case 3: s.italic = true
            case 4, 21: s.underline = true
            case 7: s.inverse = true
            case 9: s.strikethrough = true
            case 22:
                s.bold = false
                s.dim = false
            case 23: s.italic = false
            case 24: s.underline = false
            case 27: s.inverse = false
            case 29: s.strikethrough = false
            case 30...37: s.foreground = .palette(c - 30)
            case 39: s.foreground = nil
            case 40...47: s.background = .palette(c - 40)
            case 49: s.background = nil
            case 90...97: s.foreground = .palette(c - 90 + 8)
            case 100...107: s.background = .palette(c - 100 + 8)
            case 38, 48:
                let mode = i + 1 < codes.count ? codes[i + 1] : -1
                var color: AnsiColor?
                if mode == 5 {
                    let n = i + 2 < codes.count ? codes[i + 2] : 0
                    color = .palette(min(max(n, 0), 255))
                    i += 2
                } else if mode == 2 {
                    // "38;2;r;g;b" and the colon form "38:2::r:g:b" (empty color-space id).
                    var j = i + 2
                    if colonForm, j < codes.count, codes[j] == 0, codes.count - j >= 4 { j += 1 }
                    func byte(_ k: Int) -> UInt8 { k < codes.count ? UInt8(clamping: codes[k]) : 0 }
                    color = .rgb(byte(j), byte(j + 1), byte(j + 2))
                    i = j + 2
                } else {
                    i = codes.count  // malformed: ignore the rest
                }
                if let color {
                    if c == 38 { s.foreground = color } else { s.background = color }
                }
            default:
                break  // blink, fonts, … are ignored
            }
            i += 1
        }
        return s
    }
}

/// The theme's 16 ANSI colors (docs/ui-mockup-v2.html / v1 styles.css `--ansi-N`).
public enum AnsiPalette {
    public static let light: [UInt32] = [
        0x1D1D20, 0xC23B2F, 0x1F8A4C, 0xA86B00, 0x2F6FDE, 0xA03FB0, 0x13849A, 0x8D8D96,
        0x8D8D96, 0xD33A2C, 0x1F9D55, 0xC27C0E, 0x4B83E8, 0xB552C4, 0x1798B0, 0x5F5F68,
    ]
    public static let dark: [UInt32] = [
        0x6E6E78, 0xEF6A5C, 0x3FBF75, 0xE0A23A, 0x5B8FF0, 0xC38AE0, 0x4CC3D6, 0xD6D6DC,
        0x8A8A94, 0xFF8577, 0x5FD893, 0xF2BF5E, 0x7EA8F6, 0xD6A4EE, 0x74D6E6, 0xF2F2F5,
    ]
}
