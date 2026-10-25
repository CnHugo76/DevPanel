import AppKit
import DevPanelKit
import SwiftUI

/// Disconnected: everything is shown from the last known state, greyed, with actions disabled.
struct StaleKey: EnvironmentKey {
    static let defaultValue = false
}

/// `--snapshot` turns hover highlights off (the real cursor may sit over the hidden window).
struct HoverEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isStale: Bool {
        get { self[StaleKey.self] }
        set { self[StaleKey.self] = newValue }
    }

    var hoverEnabled: Bool {
        get { self[HoverEnabledKey.self] }
        set { self[HoverEnabledKey.self] = newValue }
    }
}

enum Copy {
    static let staleReason = "与管理服务的连接中断，操作暂时不可用"
}

/// Status / resource values while disconnected: dimmed and desaturated (mockup `.stale`).
struct StaleDimmed: ViewModifier {
    @Environment(\.isStale) private var stale

    func body(content: Content) -> some View {
        content.opacity(stale ? 0.45 : 1)
    }
}

extension View {
    func staleDimmed() -> some View { modifier(StaleDimmed()) }
}

/// `● 运行中` — glyph + text in a rounded pill (mockup `.st-pill`).
struct StatusPill: View {
    let label: StatusLabel
    @Environment(\.isStale) private var stale

    var body: some View {
        let c = Theme.colors(stale ? .gray : label.tone)
        HStack(spacing: 5) {
            Text(label.glyph.symbol).font(.system(size: 10))
            Text(label.text).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 11.5, weight: label.tone == .amberStrong ? .semibold : .regular))
        .monospacedDigit()
        .foregroundStyle(c.fg)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(c.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(c.border, style: StrokeStyle(lineWidth: 1, dash: label.tone == .purple ? [3, 2] : [])))
        .help(label.text)
        .staleDimmed()
    }
}

/// Project badge: `2/2 运行中` (mockup `.count`).
struct CountBadge: View {
    let label: StatusLabel
    @Environment(\.isStale) private var stale

    var body: some View {
        let colored = label.tone != .gray && !stale
        let c = Theme.colors(label.tone)
        Text(label.text)
            .font(.system(size: 11.5))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(colored ? c.fg : Theme.text2)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(colored ? c.bg : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(colored ? c.border : Theme.line2))
            .fixedSize()
            .staleDimmed()
    }
}

/// 28×28 borderless icon button (mockup `.icon-btn`).
struct IconButton: View {
    enum Role { case play, stop, plain }

    let symbol: String
    var role: Role = .plain
    var size: CGFloat = 28
    let help: String
    var enabled = true
    var pending = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if pending {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(symbol).font(.system(size: 12.5))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(IconButtonStyle(role: role))
        .disabled(!enabled || pending)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct IconButtonStyle: ButtonStyle {
    let role: IconButton.Role
    @Environment(\.isEnabled) private var enabled
    @Environment(\.hoverEnabled) private var hoverEnabled
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover && enabled ? Theme.graySoft : .clear))
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.3)
            .onHover { hover = $0 && hoverEnabled }
    }

    private var color: Color {
        switch role {
        case .play: Theme.green
        case .stop: Theme.red
        case .plain: Theme.text2
        }
    }
}

/// `⋯` menu with the icon-button look.
struct MoreMenu<Content: View>: View {
    var size: CGFloat = 28
    var help = "更多"
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Text("⋯").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Theme.text2)
        .foregroundStyle(Theme.text2)
        .frame(width: size, height: size)
        .help(help)
    }
}

/// Red "强制停止" (mockup `.force`).
struct ForceStopButton: View {
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("强制停止")
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.red, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(enabled ? "向仍存活的受管进程发送 SIGKILL" : Copy.staleReason)
    }
}

/// `8081 ↗` (+ `局域网`), opens http://localhost:<port>.
struct PortChipView: View {
    let chip: PortChip
    @Environment(\.isStale) private var stale
    /// Narrow column: "局域网" becomes an amber dot (still explained in the help).
    var shortLAN = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(chip.url)
        } label: {
            HStack(spacing: 3) {
                Text("\(String(chip.port)) ↗")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(stale ? Theme.text2 : Theme.accent2)
                if chip.lan {
                    if shortLAN {
                        Circle().fill(Theme.amber).frame(width: 4, height: 4)
                    } else {
                        Text("局域网")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.amber)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(stale ? Theme.graySoft : Theme.accentSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(chip.help)
        .pointerStyleLink()
    }
}

/// Right-aligned number or a dimmed placeholder ("采样中" / "不可用" / "—").
struct MetricCell: View {
    let metric: MetricText
    @Environment(\.isStale) private var stale

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                row(tag: true)
                row(tag: false)
            }
        }
        .font(.system(size: 13))
        .monospacedDigit()
        .help(metric.help ?? "")
        .modifier(MetricDim(kind: metric.kind))
    }
}

extension MetricCell {
    /// Value, then "部分" — or only an amber dot when the column is too narrow.
    fileprivate func row(tag: Bool) -> some View {
        HStack(spacing: 4) {
            // Disconnected: an explicit gray (filters do not render in `--snapshot`).
            Text(metric.text)
                .minimumScaleFactor(0.75)
                .foregroundStyle(metric.kind == .value && !stale ? Theme.text : Theme.text3)
                .lineLimit(1)
            if metric.partial {
                if tag {
                    Text("部分").font(.system(size: 10)).foregroundStyle(stale ? Theme.text3 : Theme.amber)
                } else {
                    Circle().fill(stale ? Theme.text3 : Theme.amber).frame(width: 4, height: 4)
                }
            }
        }
        .fixedSize(horizontal: tag, vertical: true)
    }
}

private struct MetricDim: ViewModifier {
    let kind: MetricText.Kind
    func body(content: Content) -> some View {
        if kind == .none { content } else { content.staleDimmed() }
    }
}

/// Compact editable option; full name and value remain available in help and the editor.
struct ParamChipView: View {
    let chip: ParamChip

    var body: some View {
        HStack(spacing: 6) {
            if chip.byAgent {
                Text("✦").font(.system(size: 11)).foregroundStyle(Theme.accent2)
            }
            Text(chip.label).foregroundStyle(Theme.text2).lineLimit(1)
            Text(chip.value)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if chip.pending {
                Circle().fill(Theme.amber).frame(width: 5, height: 5)
            }
            Text("▾").font(.system(size: 9)).foregroundStyle(Theme.text3)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(maxWidth: 360)
        .frame(height: 24)
        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    chip.pending ? Theme.amber.opacity(0.7) : Theme.line,
                    style: StrokeStyle(lineWidth: 1, dash: chip.pending ? [3, 2] : [])))
        .help(chip.help)
    }
}

extension View {
    /// Pointing-hand cursor (macOS 15+); no-op on 14.
    @ViewBuilder func pointerStyleLink() -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(.link)
        } else {
            self
        }
    }
}

/// Lets the custom title bar drag the window (the system title bar is hidden).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ReadyBadge: View {
    let ready: ReadyInfo?
    var body: some View {
        if let ready, let label = ready.label {
            HStack(spacing: 4) {
                if ready.state == .waiting { ProgressView().controlSize(.mini) }
                Text(label)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(ready.state == .ready ? Theme.green : ready.state == .timedOut ? Theme.amber : Theme.text3)
            .help(ready.explanation)
        }
    }
}
