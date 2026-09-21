import SwiftUI

/// One of the permissions the introduction asks for.
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
            // The cards are equal height but their content is top-aligned, so a wrapped title would push the status line down.
            Spacer(minLength: DS.Spacing.small)
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
                    .lineLimit(1)
                    // "Apri Impostazioni di Sistema…" is 15 pt wider than a third of the column.
                    .minimumScaleFactor(0.85)
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
