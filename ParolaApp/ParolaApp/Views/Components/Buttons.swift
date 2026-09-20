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

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.bodyStrong)
            .foregroundStyle(foreground)
            .frame(minWidth: size == .regular ? 104 : nil, minHeight: size == .regular ? 36 : 28)
            .padding(.horizontal, size == .regular ? DS.Spacing.medium : DS.Spacing.regular)
            .background(background(pressed: configuration.isPressed))
            .clipShape(Capsule())
            .overlay {
                if kind == .secondary {
                    Capsule().strokeBorder(DS.Color.separator, lineWidth: 0.5)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.4)
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

/// A drawn icon chip for a pull-down: `.borderlessButton` hands the label to AppKit, which drops it.
struct DSIconChipButtonStyle: ButtonStyle {
    var side: CGFloat = 22
    /// A chip carrying a word instead of a glyph: `side` is then only its height, and the label sets the width.
    var fitsLabel = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.bodyStrong)
            .foregroundStyle(DS.Color.secondaryText)
            .padding(.horizontal, fitsLabel ? DS.Spacing.snug : 0)
            .frame(width: fitsLabel ? nil : side, height: side)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(configuration.isPressed ? DS.Palette.pillFillHover : DS.Color.surfaceElevated)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
    }
}
