import SwiftUI

struct PillPickerButton<MenuContent: View>: View {
    let icon: String
    let caption: String
    let value: String
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var isPresented = false
    @State private var hovering = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.accent)
                    .frame(width: 14)
                Text(value)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
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
        .onHover { hovering = $0 }
        .accessibilityLabel("\(caption): \(value)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            menuContent()
                .padding(.vertical, 6)
                .frame(minWidth: 240)
        }
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
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
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
    let leadingSystemImage: String?
    let leadingTint: Color?
    let action: () -> Void

    @State private var hovering = false

    init(
        title: String,
        isSelected: Bool = false,
        trailingText: String? = nil,
        leadingSystemImage: String? = nil,
        leadingTint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isSelected = isSelected
        self.trailingText = trailingText
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
                Spacer()
                if let trailingText {
                    Text(trailingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? Color.secondary.opacity(0.18) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PillPopoverSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
