import SwiftUI

struct SheetFrame<Content: View, Footer: View>: View {
    let icon: String
    let iconTint: Color
    private let titleText: Text
    let onClose: () -> Void
    let content: Content
    let footer: Footer?

    init(
        icon: String,
        iconTint: Color = DS.Color.accent,
        title: LocalizedStringKey,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.titleText = Text(title)
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    init(
        icon: String,
        iconTint: Color = DS.Color.accent,
        titleVerbatim: String,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.titleText = Text(titleVerbatim)
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let footer {
                Divider()
                footer
                    .padding(.horizontal, DS.Spacing.regular)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 480)
        .frame(minHeight: 220, maxHeight: 640)
        .background(DS.Color.surface)
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.regular) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 28, height: 28)
                .background(iconTint.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            titleText
                .font(.title3.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: DS.Spacing.small)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(DS.Color.surfaceElevated)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .axLeaf("Sheet.Button.Close")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, 12)
    }
}

extension SheetFrame where Footer == EmptyView {
    init(
        icon: String,
        iconTint: Color = DS.Color.accent,
        title: LocalizedStringKey,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.titleText = Text(title)
        self.onClose = onClose
        self.content = content()
        self.footer = nil
    }

    init(
        icon: String,
        iconTint: Color = DS.Color.accent,
        titleVerbatim: String,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.titleText = Text(titleVerbatim)
        self.onClose = onClose
        self.content = content()
        self.footer = nil
    }
}

struct SheetActionPill: ButtonStyle {
    enum Kind { case primary, secondary }

    let kind: Kind
    var minWidth: CGFloat = 104

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(foreground)
            .frame(minWidth: minWidth, minHeight: 36)
            .padding(.horizontal, DS.Spacing.medium)
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
        case .primary: return .white
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
        buttonStyle(SheetActionPill(kind: .primary))
    }

    func sheetSecondaryAction() -> some View {
        buttonStyle(SheetActionPill(kind: .secondary))
    }
}
