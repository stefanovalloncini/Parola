import SwiftUI

struct DSPillButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    enum Size {
        case regular
        case compact
    }

    let kind: Kind
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .regular ? DS.Font.bodyMedium : DS.Font.calloutEmphasized)
            .foregroundStyle(foreground)
            .frame(minWidth: size == .regular ? 104 : nil, minHeight: size == .regular ? 36 : 28)
            .padding(.horizontal, size == .regular ? DS.Spacing.medium : 14)
            .background(background(pressed: configuration.isPressed))
            .clipShape(Capsule())
            .overlay {
                if kind == .secondary {
                    Capsule().strokeBorder(DS.Color.separator, lineWidth: 0.5)
                }
            }
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return DS.Color.onAccent
        case .secondary: return DS.Color.primaryText
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary:
            return DS.Color.accent.opacity(pressed ? 0.85 : 1.0)
        case .secondary:
            return DS.Color.surfaceElevated
        }
    }
}

extension View {
    func sheetPrimaryAction() -> some View {
        buttonStyle(DSPillButtonStyle(kind: .primary))
    }

    func sheetSecondaryAction() -> some View {
        buttonStyle(DSPillButtonStyle(kind: .secondary))
    }
}

/// The switch every settings row's trailing accessory wears. Checkboxes stay for inline labelled
/// options inside a rule editor, where the label sits next to the box.
struct DSSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DS.Color.accent)
    }
}

struct DSIconChip: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(DS.Font.subheadlineEmphasized)
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(DS.Color.surfaceElevated)
            )
    }
}
