import SwiftUI

struct PillPickerButton<MenuContent: View>: View {
    let icon: String
    let caption: String
    let value: String
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DS.Color.accent.opacity(0.18))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Color.accent)
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            menuContent()
                .padding(.vertical, 6)
                .frame(minWidth: 240)
        }
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
