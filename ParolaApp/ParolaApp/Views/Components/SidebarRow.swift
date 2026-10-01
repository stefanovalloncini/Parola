import SwiftUI

struct SidebarRow: View {
    private let titleText: Text
    let systemImage: String
    let isSelected: Bool
    let height: CGFloat
    /// The colour of the row's group, which the glyph's badge wears.
    let iconTint: Color
    let action: () -> Void

    init(
        title: LocalizedStringKey,
        systemImage: String,
        isSelected: Bool,
        height: CGFloat = 32,
        iconTint: Color,
        action: @escaping () -> Void
    ) {
        self.titleText = Text(title)
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.height = height
        self.iconTint = iconTint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SidebarRowLabel(
                text: titleText,
                systemImage: systemImage,
                isSelected: isSelected,
                height: height,
                iconTint: iconTint
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SidebarRowLabel: View {
    private let titleText: Text
    let systemImage: String
    let isSelected: Bool
    let height: CGFloat
    let iconTint: Color

    init(
        text: Text,
        systemImage: String,
        isSelected: Bool = false,
        height: CGFloat = 32,
        iconTint: Color
    ) {
        self.titleText = text
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.height = height
        self.iconTint = iconTint
    }

    static let badgeSide: CGFloat = 20

    /// The solid accent a chosen sidebar row wears; its labels name their own onAccent tiers, so it carries no foreground.
    static var selectionStyle: RowSelectionStyle {
        .prominent(fill: DS.Color.selectionProminent)
    }

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: systemImage)
                .font(DS.Font.caption)
                .foregroundStyle(isSelected ? DS.Color.onAccent : iconTint)
                .frame(width: Self.badgeSide, height: Self.badgeSide)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .fill(isSelected ? DS.Color.onAccentWash : iconTint.opacity(0.18))
                )
            titleText
                .font(DS.Font.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? DS.Color.onAccent : .primary)
        .padding(.horizontal, DS.Spacing.small)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowChrome(selected: isSelected, hovered: isHovering, selection: Self.selectionStyle)
        .onHover { isHovering = $0 }
    }
}
