import SwiftUI

struct PillPickerButton<MenuContent: View>: View {
    let icon: String
    let caption: String
    let value: String
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var isPresented = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.accent)
                    .frame(width: 14)
                Text(value)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(DS.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.tight)
            .frame(height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0.06))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = isEnabled && $0 }
        .accessibilityLabel("\(caption): \(value)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            menuContent()
                .padding(.vertical, DS.Spacing.snug)
                .frame(minWidth: 240)
        }
        .axLeaf("Pill.Button.\(caption)")
    }
}

struct PillToggleButton: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool

    @State private var hovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(DS.Font.bodyStrong)
                    .frame(width: 14)
                Text(label)
                    .font(DS.Font.bodyStrong)
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? DS.Color.onAccent : Color.primary)
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.tight)
            .frame(height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
        .axLeaf("Pill.Toggle.\(label)")
    }

    private var fillColor: Color {
        if isOn { return DS.Color.accent.opacity(hovering ? 0.95 : 0.85) }
        return Color.primary.opacity(hovering ? 0.10 : 0.06)
    }

    private var borderColor: Color {
        isOn ? DS.Color.accent.opacity(0.45) : Color.primary.opacity(0.08)
    }
}

struct PillPopoverRow: View {
    let title: String
    let isSelected: Bool
    let trailingText: String?
    let badgeText: String?
    let help: String?
    let leadingSystemImage: String?
    let leadingTint: Color?
    let action: () -> Void

    @State private var hovering = false

    init(
        title: String,
        isSelected: Bool = false,
        trailingText: String? = nil,
        badgeText: String? = nil,
        help: String? = nil,
        leadingSystemImage: String? = nil,
        leadingTint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isSelected = isSelected
        self.trailingText = trailingText
        self.badgeText = badgeText
        self.help = help
        self.leadingSystemImage = leadingSystemImage
        self.leadingTint = leadingTint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let leadingSystemImage {
                    Image(systemName: leadingSystemImage)
                        .foregroundStyle(leadingTint ?? .secondary)
                        .frame(width: 16)
                } else {
                    Spacer().frame(width: 16)
                }
                Text(title)
                    .foregroundStyle(.primary)
                if let badgeText {
                    Text(verbatim: badgeText)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .padding(.horizontal, DS.Spacing.tight)
                        .padding(.vertical, 1)
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.08)))
                }
                Spacer()
                if let trailingText {
                    Text(trailingText)
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                Image(systemName: "checkmark")
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(hovering ? Color.secondary.opacity(0.18) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .modifier(OptionalHelp(help: help))
        .axLeaf("Pill.PopoverRow.\(title)")
    }
}

struct PillPopoverSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.secondaryText)
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.top, DS.Spacing.small)
            .padding(.bottom, DS.Spacing.hair)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
