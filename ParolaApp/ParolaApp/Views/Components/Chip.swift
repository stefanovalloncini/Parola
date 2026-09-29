import SwiftUI

struct Chip: View {
    enum Size {
        case compact
        case regular
        case prominent
    }

    enum Style {
        case elevated
        case subtle
    }

    var title: LocalizedStringKey = ""
    /// Bypasses `title`'s localization + markdown parsing for runtime data (e.g. speaker names that can contain `*` or `_`).
    var verbatimTitle: String? = nil
    var tint: Color? = nil
    var isSelected: Bool
    var size: Size = .compact
    var weight: Font.Weight = .medium
    var style: Style = .elevated
    var selectedFill: Color = DS.Color.accentFill
    var bordered: Bool = true
    var identifier: String? = nil
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                }
                titleLabel
                    .font(size.font(weight: weight))
                    .foregroundStyle(foreground)
            }
            .chipChrome(
                isSelected: isSelected,
                size: size,
                style: style,
                hovering: hovering,
                selectedFill: selectedFill,
                bordered: bordered
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .modifier(OptionalHelp(help: help))
        .modifier(OptionalIdentifier(identifier: identifier))
        .modifier(SelectedTrait(isSelected: isSelected))
    }

    private var titleLabel: Text {
        if let verbatimTitle {
            return Text(verbatim: verbatimTitle)
        }
        return Text(title)
    }

    private var foreground: Color {
        switch style {
        case .elevated:
            return isSelected ? DS.Color.onAccent : .primary.opacity(0.85)
        case .subtle:
            return isSelected ? DS.Color.onAccent : .primary
        }
    }

}

extension View {
    /// The capsule every filter control wears: `Chip` for buttons, `LibraryFilterBar` for pull-downs.
    func chipChrome(
        isSelected: Bool,
        size: Chip.Size = .compact,
        style: Chip.Style = .elevated,
        hovering: Bool = false,
        pressed: Bool = false,
        selectedFill: Color = DS.Color.accentFill,
        bordered: Bool = true,
        border overrideBorder: Color? = nil,
        horizontalPadding: CGFloat? = nil
    ) -> some View {
        let fill: Color
        let lit = hovering || pressed
        if isSelected {
            fill = selectedFill
        } else {
            switch style {
            case .elevated: fill = lit ? DS.Color.surfaceElevated : DS.Color.surfaceElevated.opacity(0.6)
            case .subtle: fill = lit ? DS.Color.surfaceElevated : Color.primary.opacity(0.06)
            }
        }
        let border: Color = bordered
            ? (overrideBorder ?? (isSelected ? selectedFill.opacity(0.45) : DS.Color.separator.opacity(0.4)))
            : .clear
        return padding(.horizontal, horizontalPadding ?? size.horizontalPadding)
            .frame(height: size.height)
            .background(Capsule(style: .continuous).fill(fill))
            .overlay(Capsule(style: .continuous).strokeBorder(border, lineWidth: 0.5))
            .contentShape(Capsule(style: .continuous))
            .rowStateAnimation(RowChromeState(selected: isSelected, hovered: hovering))
    }
}

/// A filter chip that opens a menu: `.borderlessButton` would replace the label with an AppKit title.
struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool
    var size: Chip.Size = .compact
    var weight: Font.Weight = .medium

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, isSelected: isSelected, size: size, weight: weight)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let isSelected: Bool
        let size: Chip.Size
        let weight: Font.Weight
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(size.font(weight: weight))
                .foregroundStyle(isSelected ? DS.Color.onAccent : Color.primary.opacity(0.85))
                .chipChrome(
                    isSelected: isSelected,
                    size: size,
                    hovering: hovering,
                    pressed: configuration.isPressed
                )
                .onHover { hovering = $0 }
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

extension Chip.Size {
    func font(weight: Font.Weight) -> Font {
        switch self {
        case .compact: return DS.Font.caption.weight(weight)
        case .regular: return DS.Font.secondary.weight(weight)
        case .prominent: return DS.Font.body.weight(weight)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact, .regular: return 10
        case .prominent: return 12
        }
    }

    var height: CGFloat {
        switch self {
        case .compact: return 22
        case .regular: return 24
        case .prominent: return 28
        }
    }
}

struct OptionalHelp: ViewModifier {
    let help: String?
    func body(content: Content) -> some View {
        if let help { content.help(help) } else { content }
    }
}

private struct OptionalIdentifier: ViewModifier {
    let identifier: String?
    func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}

private struct SelectedTrait: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        content.accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
