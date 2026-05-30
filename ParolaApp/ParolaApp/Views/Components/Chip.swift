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

    let title: LocalizedStringKey
    var tint: Color? = nil
    var isSelected: Bool
    var size: Size = .compact
    var weight: Font.Weight = .medium
    var style: Style = .elevated
    var selectedFill: Color = DS.Color.accent
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
                Text(title)
                    .font(font)
                    .foregroundStyle(foreground)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .modifier(OptionalHelp(help: help))
        .modifier(OptionalIdentifier(identifier: identifier))
        .modifier(SelectedTrait(isSelected: isSelected))
    }

    private var font: Font {
        switch size {
        case .compact: return DS.Font.subheadline.weight(weight)
        case .regular: return DS.Font.caption.weight(weight)
        case .prominent: return DS.Font.callout.weight(weight)
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .compact: return 10
        case .regular: return 10
        case .prominent: return 12
        }
    }

    private var height: CGFloat {
        switch size {
        case .compact: return 22
        case .regular: return 24
        case .prominent: return 28
        }
    }

    private var foreground: Color {
        switch style {
        case .elevated:
            return isSelected ? .white : .primary.opacity(0.85)
        case .subtle:
            return isSelected ? .white : .primary
        }
    }

    private var background: Color {
        if isSelected { return selectedFill }
        switch style {
        case .elevated:
            return hovering ? DS.Color.surfaceElevated : DS.Color.surfaceElevated.opacity(0.6)
        case .subtle:
            return hovering ? DS.Color.surfaceElevated : Color.primary.opacity(0.06)
        }
    }

    private var border: Color {
        guard bordered else { return .clear }
        if isSelected { return selectedFill.opacity(0.45) }
        return DS.Color.separator.opacity(0.4)
    }
}

private struct OptionalHelp: ViewModifier {
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
