import SwiftUI

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let isFirst: Bool
    let axID: String
    let action: () -> Void
    let actionLabel: String

    var body: some View {
        SettingRow(titleVerbatim: title, descriptionVerbatim: detail, isFirst: isFirst) {
            HStack(spacing: 8) {
                Circle()
                    .fill(granted ? DS.Palette.success : DS.Palette.warning)
                    .frame(width: 8, height: 8)
                Text(granted ? String(localized: "Granted") : String(localized: "Not granted"))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                if !granted {
                    Button(actionLabel, action: action)
                        .axLeaf(axID)
                }
            }
        }
    }
}
