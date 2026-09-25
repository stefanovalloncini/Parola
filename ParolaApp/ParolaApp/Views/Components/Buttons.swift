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

    // Computed, not stored: a stored pair would freeze the palette the app launched with.
    static var disabledFill: Color { DS.Palette.subtleFill }
    static var disabledLabel: Color { DS.Color.secondaryText }

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, kind: kind, size: size)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
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
                .opacity(dimsWholeView && !isEnabled ? DS.Opacity.disabled : (configuration.isPressed ? 0.85 : 1.0))
                .contentShape(Capsule())
                .rowStateAnimation(hovering)
                .onHover { hovering = $0 }
        }

        /// Only the secondary pill fades whole: the primary swaps its pair instead, so neither half thins out.
        private var dimsWholeView: Bool { kind == .secondary }

        private var foreground: Color {
            switch kind {
            case .primary: return isEnabled ? DS.Color.onAccent : DSPillButtonStyle.disabledLabel
            case .secondary: return DS.Color.primaryText
            }
        }

        /// The primary pill is the chosen one, and a chosen row takes no hover.
        private func background(pressed: Bool) -> Color {
            switch kind {
            case .primary:
                return isEnabled ? DS.Color.accent.opacity(pressed ? 0.85 : 1.0) : DSPillButtonStyle.disabledFill
            case .secondary:
                return isEnabled && hovering ? DS.Palette.pillFillHover : DS.Color.surfaceElevated
            }
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
        Chrome(configuration: configuration, side: side, fitsLabel: fitsLabel)
    }

    /// The pointer already lights the chip, so a press dims it: a click whose result paints late still shows it landed.
    static func opacity(enabled: Bool, pressed: Bool) -> Double {
        guard enabled else { return DS.Opacity.disabled }
        return pressed ? 0.85 : 1
    }

    private struct Chrome: View {
        let configuration: Configuration
        let side: CGFloat
        let fitsLabel: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(DS.Font.bodyStrong)
                .foregroundStyle(DS.Color.secondaryText)
                .padding(.horizontal, fitsLabel ? DS.Spacing.snug : 0)
                .frame(width: fitsLabel ? nil : side, height: side)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .fill(lit ? DS.Palette.pillFillHover : DS.Color.surfaceElevated)
                )
                .opacity(DSIconChipButtonStyle.opacity(enabled: isEnabled, pressed: configuration.isPressed))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                .rowStateAnimation(hovering)
                .onHover { hovering = $0 }
        }

        private var lit: Bool { configuration.isPressed || (isEnabled && hovering) }
    }
}

/// A glyph-only button: bare at rest, with a target larger than its glyph that lights on hover and press.
struct GlyphButtonStyle: ButtonStyle {
    var width: CGFloat
    var height: CGFloat
    /// Inks the glyph with the environment tint, as `.borderless` does.
    var tinted: Bool
    /// A toggle that is on rests on this fill and, like a selected row, takes no hover.
    var selectedFill: Color?

    static let defaultSide: CGFloat = 24
    static let shape = RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)

    init(
        width: CGFloat = GlyphButtonStyle.defaultSide,
        height: CGFloat = GlyphButtonStyle.defaultSide,
        tinted: Bool = false,
        selectedFill: Color? = nil
    ) {
        self.width = width
        self.height = height
        self.tinted = tinted
        self.selectedFill = selectedFill
    }

    init(side: CGFloat, tinted: Bool = false) {
        self.init(width: side, height: side, tinted: tinted)
    }

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, style: self)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let style: GlyphButtonStyle

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let appearance = GlyphButtonAppearance(
                hovered: hovering,
                pressed: configuration.isPressed,
                enabled: isEnabled,
                selectedFill: style.selectedFill
            )
            configuration.label
                .foregroundStyle(style.tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.foreground))
                .frame(width: style.width, height: style.height)
                .background(GlyphButtonStyle.shape.fill(appearance.fill))
                .opacity(appearance.opacity)
                .contentShape(Rectangle())
                .rowStateAnimation(hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// What a glyph button draws in one state: a chosen toggle keeps its fill, and a press outranks a hover.
struct GlyphButtonAppearance: Equatable {
    var fill: Color
    var opacity: Double

    static var hoverFill: Color { DS.Palette.surfaceHover }
    static var pressedFill: Color { DS.Palette.pillFillHover }

    init(hovered: Bool, pressed: Bool, enabled: Bool, selectedFill: Color? = nil) {
        opacity = enabled ? 1 : DS.Opacity.disabled
        if let selectedFill {
            fill = selectedFill
        } else if !enabled {
            fill = .clear
        } else if pressed {
            fill = Self.pressedFill
        } else {
            fill = hovered ? Self.hoverFill : .clear
        }
    }
}
