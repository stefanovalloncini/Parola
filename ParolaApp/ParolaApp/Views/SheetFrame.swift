import SwiftUI

struct SheetFrame<Content: View, Footer: View>: View {
    let icon: String
    let iconTint: Color
    private let titleText: Text
    let onClose: () -> Void
    let content: Content
    let footer: Footer?
    private var width: CGFloat = 480
    private var minHeight: CGFloat = 220
    private var maxHeight: CGFloat = 640
    private var closeAXLeaf = "Sheet.Button.Close"
    private var accessory: AnyView?
    private var showsClose = true

    func sheetSize(width: CGFloat, minHeight: CGFloat = 220, maxHeight: CGFloat = 640) -> SheetFrame {
        var copy = self
        copy.width = width
        copy.minHeight = minHeight
        copy.maxHeight = maxHeight
        return copy
    }

    /// For sheets whose footer already ends in Cancel: two dismiss controls and two `.cancelAction`s.
    func hidesCloseButton() -> SheetFrame {
        var copy = self
        copy.showsClose = false
        return copy
    }

    func closeLeaf(_ id: String) -> SheetFrame {
        var copy = self
        copy.closeAXLeaf = id
        return copy
    }

    func headerAccessory<A: View>(@ViewBuilder _ build: () -> A) -> SheetFrame {
        var copy = self
        copy.accessory = AnyView(build())
        return copy
    }

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
        .frame(width: width)
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .background(DS.Color.surface)
        .tint(DS.Color.accent)
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.regular) {
            Image(systemName: icon)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(iconTint)
                .frame(width: 28, height: 28)
                .background(iconTint.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))

            titleText
                .font(DS.Font.heading)
                .lineLimit(1)

            Spacer(minLength: DS.Spacing.small)

            if let accessory {
                accessory
            }

            if showsClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(DS.Color.surfaceElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close")
                .axLeaf(closeAXLeaf)
            }
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

