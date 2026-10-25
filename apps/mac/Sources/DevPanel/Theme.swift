import AppKit
import DevPanelKit
import SwiftUI

/// Colors from docs/ui-mockup-v2.html (CSS variables), resolved per light / dark appearance.
enum Theme {
    static let accent = dynamic(dark: 0x7C6CF6, light: 0x6656E8)
    static let accent2 = dynamic(dark: 0x9A8CFF, light: 0x5546D6)
    static let accentSoft = dynamicAlpha(dark: (0x7C6CF6, 0.16), light: (0x6656E8, 0.10))
    static let green = dynamic(dark: 0x34C77B, light: 0x1F9D5A)
    static let greenSoft = dynamicAlpha(dark: (0x34C77B, 0.14), light: (0x1F9D5A, 0.10))
    static let red = dynamic(dark: 0xF0605A, light: 0xD8433C)
    static let redSoft = dynamicAlpha(dark: (0xF0605A, 0.14), light: (0xD8433C, 0.09))
    static let amber = dynamic(dark: 0xF0A43A, light: 0xC27C0E)
    static let amberSoft = dynamicAlpha(dark: (0xF0A43A, 0.14), light: (0xC27C0E, 0.10))
    static let purple = dynamic(dark: 0xB195FF, light: 0x7A5FD6)
    static let text = dynamic(dark: 0xECECF1, light: 0x1C1C22)
    static let text2 = dynamic(dark: 0xA3A3AE, light: 0x5D5D68)
    static let text3 = dynamic(dark: 0x6F6F7B, light: 0x8E8E99)
    static let bar = dynamic(dark: 0x18181D, light: 0xECECF0)
    static let card = dynamic(dark: 0x18181D, light: 0xFFFFFF)
    static let card2 = dynamic(dark: 0x1D1D23, light: 0xF7F7FA)
    static let line = dynamic(dark: 0x2A2A32, light: 0xE3E3E9)
    static let line2 = dynamic(dark: 0x34343D, light: 0xD4D4DC)
    static let window = dynamic(dark: 0x121216, light: 0xF6F6F8)
    static let graySoft = dynamicAlpha(dark: (0xFFFFFF, 0.06), light: (0x000000, 0.04))
    static let sel = dynamicAlpha(dark: (0x7C6CF6, 0.14), light: (0x6656E8, 0.08))
    /// `color-mix(in srgb, <c> 35%, transparent)` borders of pills.
    static func border(_ c: Color) -> Color { c.opacity(0.35) }


    /// Tone of a status → (foreground, fill, border).
    static func colors(_ tone: DisplayTone) -> (fg: Color, bg: Color, border: Color) {
        switch tone {
        case .green: (green, greenSoft, green.opacity(0.35))
        case .red: (red, redSoft, red.opacity(0.35))
        case .amber, .amberStrong: (amber, amberSoft, amber.opacity(0.35))
        case .blue: (accent2, accentSoft, accent2.opacity(0.35))
        case .purple: (purple, .clear, purple.opacity(0.6))
        case .gray: (text2, graySoft, line2)
        }
    }

    static func process(_ index: Int) -> Color {
        Color(rgb: ProcessPalette.colors[index % ProcessPalette.colors.count])
    }

    /// App icon gradient (#8f80ff → #5b4ce0).
    static let iconGradient = LinearGradient(
        colors: [Color(rgb: 0x8F80FF), Color(rgb: 0x5B4CE0)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func color(for tone: StatusTone) -> Color {
        switch tone {
        case .positive: green
        case .warning: amber
        case .negative: red
        case .neutral: text3
        }
    }


    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(rgb: dark) : NSColor(rgb: light)
        })
    }

    private static func dynamicAlpha(dark: (UInt32, CGFloat), light: (UInt32, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(rgb: dark.0, alpha: dark.1) : NSColor(rgb: light.0, alpha: light.1)
        })
    }
}

extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(rgb: UInt32) { self.init(nsColor: NSColor(rgb: rgb)) }
}

/// Service identity, deliberately a vertical stroke rather than a status light.
struct ServiceIdentityMark: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 3, height: 16)
            .accessibilityHidden(true)
    }
}
