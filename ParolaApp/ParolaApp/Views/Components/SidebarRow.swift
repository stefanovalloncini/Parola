import SwiftUI

struct SidebarRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    var badge: Int? = nil
    var height: CGFloat = 32
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: systemImage)
                    .font(DS.Font.bodyMedium)
                    .foregroundStyle(isSelected ? DS.Color.onAccent : .secondary)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(DS.Font.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text("\(badge)")
                        .font(DS.Font.captionMedium)
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
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // One shape with an animatable fill: the three states have to interpolate, not swap views.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(rowFill)
            .animation(reduceMotion ? nil : DS.Motion.rowState, value: rowFill)
    }

    private var rowFill: Color {
        if isSelected { return DS.Color.accent.opacity(0.85) }
        if isHovering { return DS.Palette.surfaceHover }
        return .clear
    }
}
