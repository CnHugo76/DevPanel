import DevPanelKit
import SwiftUI

/// Focusable fields of the editor sheet. Losing focus triggers `/config/validate`.
enum EditorField: Hashable {
    case projectName, root
    case serviceName(UUID), serviceId(UUID), cwd(UUID), command(UUID), stopTimeout(UUID)
    case envName(UUID), envValue(UUID)
}

/// A field title above its control. Clicking the title focuses the control; the control
/// carries the same text as its accessibility label (v1 fix: titles linked to inputs).
struct FieldTitle: View {
    let text: String
    var required = false
    var onTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            Text(text)
            if required { Text("*").foregroundStyle(Theme.red) }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Theme.text2)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityHidden(true)
    }
}

/// A rounded text field with the sheet's look; red border when `invalid`.
struct EditorTextField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var monospaced = false
    var invalid = false
    var secure = false
    let field: EditorField
    var focus: FocusState<EditorField?>.Binding

    var body: some View {
        Group {
            if secure {
                SecureField(label, text: $text, prompt: Text(prompt))
            } else {
                TextField(label, text: $text, prompt: Text(prompt))
            }
        }
        .labelsHidden()
        .textFieldStyle(.plain)
        .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
        .autocorrectionDisabled()
        .focused(focus, equals: field)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(invalid ? Theme.red : (focus.wrappedValue == field ? Theme.accent : Theme.line2)))
        .accessibilityLabel(label)
    }
}

/// `✕ message` / `⚠ message` / `✓ message` under a field.
struct HintLine: View {
    enum Tone { case bad, warn, ok, info }
    let tone: Tone
    let text: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(symbol)
            Text(text)
                .font(.system(size: 11.5, design: monospaced ? .monospaced : .default))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch tone {
        case .bad: "✕"
        case .warn: "⚠"
        case .ok: "✓"
        case .info: "ⓘ"
        }
    }

    private var color: Color {
        switch tone {
        case .bad: Theme.red
        case .warn: Theme.amber
        case .ok: Theme.green
        case .info: Theme.text3
        }
    }
}

/// The local error (if any) and the daemon's issues for one field.
struct FieldHints: View {
    var local: String?
    var issues: [ValidationIssue] = []

    var body: some View {
        if local != nil || !issues.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let local { HintLine(tone: .bad, text: local) }
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    if issue.message != local {
                        HintLine(tone: issue.severity == .error ? .bad : .warn, text: issue.message)
                    }
                }
            }
        }
    }
}

/// A native checkbox. Its click target is the box and its own text only (v1 fix).
struct EditorCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    var help: String?

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .fixedSize()
            .help(help ?? "")
    }
}

/// A disclosure header (`▸ 高级`) whose hit area is the arrow and its text only.
struct DisclosureHeader: View {
    let title: String
    var subtitle: String?
    @Binding var isOpen: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text(title).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityValue(isOpen ? "已展开" : "已折叠")
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Small bordered button used inside the sheet.
struct SheetButton: View {
    enum Kind { case normal, primary, danger }
    let title: String
    var kind: Kind = .normal
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: kind == .normal ? .regular : .medium))
                .foregroundStyle(kind == .normal ? Theme.text : .white)
                .padding(.horizontal, 12)
                .frame(minWidth: 64, minHeight: 26)
                .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(kind == .normal ? Theme.line2 : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var background: Color {
        switch kind {
        case .normal: Theme.card
        case .primary: Theme.accent
        case .danger: Theme.red
        }
    }
}

/// `↑` `↓` `✕` buttons of a service card.
struct CardIconButton: View {
    let systemImage: String
    let label: String
    var help: String?
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(IconButtonStyle(role: .plain))
        .disabled(!enabled)
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}
