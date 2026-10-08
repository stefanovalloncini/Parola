import SwiftUI

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let axID: String
    let action: () -> Void
    let actionLabel: String
    /// Off when the current settings don't use this permission: no dot, no warning, nothing to allow.
    var needed: Bool = true

    var body: some View {
        SettingRow(titleVerbatim: title, descriptionVerbatim: detail) {
            HStack(spacing: 8) {
                if needed {
                    status
                } else {
                    Text("Not needed")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        Circle()
            .fill(granted ? DS.Palette.success : DS.Palette.warning)
            .frame(width: 8, height: 8)
        Text(granted ? String(localized: "Granted") : String(localized: "Not granted"))
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.secondaryText)
        if !granted {
            Button(actionLabel, action: action)
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf(axID)
        }
    }
}
