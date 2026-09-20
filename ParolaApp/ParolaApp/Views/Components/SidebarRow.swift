import SwiftUI

struct SidebarRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    var badge: Int? = nil
    var height: CGFloat = 32
    /// The footer rows keep a resting outline, so they read as buttons against the empty space below the list.
    var bordered: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SidebarRowLabel(
                title: title,
                systemImage: systemImage,
                isSelected: isSelected,
                badge: badge,
                height: height,
                bordered: bordered
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The row itself, without a button around it, for the places that wrap it in one of their own (`SettingsLink`).
struct SidebarRowLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isSelected: Bool = false
    var badge: Int? = nil
    var height: CGFloat = 32
    var bordered: Bool = false

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: systemImage)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(isSelected ? DS.Color.onAccent : .secondary)
                .frame(width: 18, alignment: .center)
            Text(title)
                .font(DS.Font.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let badge {
                Text("\(badge)")
                    .font(DS.Font.caption)
                    .foregroundStyle(isSelected ? DS.Color.onAccent.opacity(0.9) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(
                            isSelected
                                ? DS.Color.onAccent.opacity(0.18)
                                : Color.primary.opacity(0.10)
                        )
                    )
            }
        }
        .foregroundStyle(isSelected ? DS.Color.onAccent : .primary)
        .padding(.horizontal, 10)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    // One shape with an animatable fill: the three states have to interpolate, not swap views.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(rowFill)
            .strokeBorder(borderColor, lineWidth: 1)
            .animation(reduceMotion ? nil : DS.Motion.rowState, value: rowFill)
    }

    private var rowFill: Color {
        if isSelected { return DS.Color.accent.opacity(0.85) }
        if isHovering { return DS.Palette.surfaceHover }
        return .clear
    }

    private var borderColor: Color {
        bordered && !isSelected ? Color.primary.opacity(0.12) : .clear
    }
}
