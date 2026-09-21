import SwiftUI

/// One permission the introduction asks for: what it is for, whether macOS has granted it, and the way to grant it.
struct PermissionCard: View {
    struct Status: Equatable {
        let label: LocalizedStringKey
        let showsAction: Bool

        init(granted: Bool) {
            label = granted ? "Granted" : "Not granted"
            showsAction = !granted
        }
    }

    let title: String
    let detail: String
    let granted: Bool
    let axID: String
    let action: () -> Void
    let actionLabel: String

    var body: some View {
        let status = Status(granted: granted)
        return VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(verbatim: title)
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: detail)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Spacing.small) {
                Circle()
                    .fill(granted ? DS.Palette.success : DS.Palette.warning)
                    .frame(width: 8, height: 8)
                Text(status.label)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            if status.showsAction {
                Button(actionLabel, action: action)
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf(axID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DS.Spacing.medium)
        .background(
            DS.Color.surfaceElevated,
            in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
        )
    }
}
