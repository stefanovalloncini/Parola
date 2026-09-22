import SwiftUI

struct SidebarRow: View {
    private let titleText: Text
    let systemImage: String
    let isSelected: Bool
    let badge: Int?
    let height: CGFloat
    /// The footer rows keep a resting outline, so they read as buttons against the empty space below the list.
    let bordered: Bool
    /// Set where the rows belong to groups: the glyph sits in a badge of the group's colour.
    let iconTint: Color?
    let action: () -> Void

    init(
        title: LocalizedStringKey,
        systemImage: String,
        isSelected: Bool,
        badge: Int? = nil,
        height: CGFloat = 32,
        bordered: Bool = false,
        iconTint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.titleText = Text(title)
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.badge = badge
        self.height = height
        self.bordered = bordered
        self.iconTint = iconTint
        self.action = action
    }

    /// For rows named after something the user typed, which must never be looked up as a key.
    init(
        titleVerbatim: String,
        systemImage: String,
        isSelected: Bool,
        badge: Int? = nil,
        height: CGFloat = 32,
        bordered: Bool = false,
        iconTint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.titleText = Text(verbatim: titleVerbatim)
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.badge = badge
        self.height = height
        self.bordered = bordered
        self.iconTint = iconTint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SidebarRowLabel(
                text: titleText,
                systemImage: systemImage,
                isSelected: isSelected,
                badge: badge,
                height: height,
                bordered: bordered,
                iconTint: iconTint
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The row itself, without a button around it, for the places that wrap it in one of their own (`SettingsLink`).
struct SidebarRowLabel: View {
    private let titleText: Text
    let systemImage: String
    let isSelected: Bool
    let badge: Int?
    let height: CGFloat
    let bordered: Bool
    let iconTint: Color?

    init(
        text: Text,
        systemImage: String,
        isSelected: Bool = false,
        badge: Int? = nil,
        height: CGFloat = 32,
        bordered: Bool = false,
        iconTint: Color? = nil
    ) {
        self.titleText = text
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.badge = badge
        self.height = height
        self.bordered = bordered
        self.iconTint = iconTint
    }

    init(
        title: LocalizedStringKey,
        systemImage: String,
        isSelected: Bool = false,
        badge: Int? = nil,
        height: CGFloat = 32,
        bordered: Bool = false,
        iconTint: Color? = nil
    ) {
        self.init(
            text: Text(title), systemImage: systemImage, isSelected: isSelected,
            badge: badge, height: height, bordered: bordered, iconTint: iconTint
        )
    }

    static let badgeSide: CGFloat = 20

    /// The solid accent a chosen sidebar row wears; its labels name their own onAccent tiers, so it carries no foreground.
    static var selectionStyle: RowSelectionStyle {
        .prominent(fill: DS.Color.selectionProminent)
    }

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            if let iconTint {
                icon
                    .font(DS.Font.caption)
                    .foregroundStyle(isSelected ? DS.Color.onAccent : iconTint)
                    .frame(width: Self.badgeSide, height: Self.badgeSide)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                            .fill(isSelected ? DS.Color.onAccentWash : iconTint.opacity(0.18))
                    )
            } else {
                icon
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(isSelected ? DS.Color.onAccent : .secondary)
                    .frame(width: 18, alignment: .center)
            }
            titleText
                .font(DS.Font.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let badge {
                Text("\(badge)")
                    .font(DS.Font.caption)
                    .foregroundStyle(isSelected ? DS.Color.onAccentSecondary : .secondary)
                    .padding(.horizontal, DS.Spacing.snug)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(
                            isSelected
                                ? DS.Color.onAccentWash
                                : Color.primary.opacity(0.10)
                        )
                    )
            }
        }
        .foregroundStyle(isSelected ? DS.Color.onAccent : .primary)
        .padding(.horizontal, DS.Spacing.small)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .rowChrome(selected: isSelected, hovered: isHovering, selection: Self.selectionStyle)
        .onHover { isHovering = $0 }
    }

    private var icon: some View {
        Image(systemName: systemImage)
    }

    private var borderColor: Color {
        bordered && !isSelected ? Color.primary.opacity(0.12) : .clear
    }
}
