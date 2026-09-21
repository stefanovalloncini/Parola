import SwiftUI
import ParolaCore

struct ReadyScene: View {
    enum PermissionKind: String, Identifiable {
        case microphone
        case systemAudio
        case accessibility

        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model

    static func permissionRows(features: FeatureSet) -> [PermissionKind] {
        var rows: [PermissionKind] = []
        if features.isEnabled(.micRecording) || features.isEnabled(.dictation)
            || features.isEnabled(.liveCaptions) {
            rows.append(.microphone)
        }
        if features.isEnabled(.meetings) { rows.append(.systemAudio) }
        if features.isEnabled(.dictation) { rows.append(.accessibility) }
        return rows
    }

    var body: some View {
        let rows = Self.permissionRows(features: model.features)
        return VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("You're ready.")
                .font(DS.Font.hero)
                .foregroundStyle(DS.Color.primaryText)
                .sceneEntrance(order: 0)
            if !rows.isEmpty {
                Text("Grant a permission now, or the first time you use its feature.")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.secondaryText)
                    .sceneEntrance(order: 1)
                HStack(alignment: .top, spacing: DS.Spacing.medium) {
                    ForEach(rows) { kind in
                        permissionCard(kind)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Spacing.small)
                .sceneEntrance(order: 2)
            }
            modelStatus
                .sceneEntrance(order: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            model.capturePermissions.refresh()
            model.dictationPermissions.refresh()
        }
    }

    @ViewBuilder
    private func permissionCard(_ kind: PermissionKind) -> some View {
        switch kind {
        case .microphone:
            PermissionCard(
                title: String(localized: "Microphone"),
                detail: String(localized: "Captures your voice for recordings and dictation."),
                granted: model.dictationPermissions.microphoneAuthorized,
                axID: "Introduction.Button.GrantMicrophone",
                action: {
                    if model.dictationPermissions.microphoneUndetermined {
                        model.dictationPermissions.requestMicrophone()
                    } else {
                        model.dictationPermissions.openMicrophoneSettings()
                    }
                },
                actionLabel: String(localized: "Allow…")
            )
        case .systemAudio:
            PermissionCard(
                title: String(localized: "System Audio Recording"),
                detail: String(localized: "Records meetings and anything else your Mac plays."),
                granted: model.capturePermissions.systemAudioGranted,
                axID: "Introduction.Button.GrantSystemAudio",
                action: { model.capturePermissions.requestSystemAudio() },
                actionLabel: String(localized: "Allow…")
            )
        case .accessibility:
            PermissionCard(
                title: String(localized: "Accessibility"),
                detail: String(localized: "Watches for the dictation hotkey and inserts text where you type."),
                granted: model.dictationPermissions.accessibilityGranted,
                axID: "Introduction.Button.GrantAccessibility",
                action: { model.dictationPermissions.openAccessibilitySettings() },
                actionLabel: String(localized: "Open System Settings…")
            )
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch model.phase {
        case .downloadingModel(let name, let progress):
            statusCard {
                Text("\(AppModel.modelLabel(name)) keeps downloading in the background.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Spacing.small) {
                    DSProgressBar(value: progress)
                    Text(AppFormat.percent(progress))
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
        case .failed(let message):
            statusCard {
                Text(message)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            EmptyView()
        }
    }

    private func statusCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.medium)
        .background(
            DS.Palette.surface,
            in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
        )
        .padding(.top, DS.Spacing.small)
    }
}
