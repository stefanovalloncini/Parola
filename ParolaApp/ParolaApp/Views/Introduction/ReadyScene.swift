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
            if !rows.isEmpty {
                Text("Grant a permission now, or the first time you use its feature.")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.secondaryText)
                SettingsSection {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, kind in
                        permissionRow(kind, isFirst: index == 0)
                    }
                }
                .padding(.top, DS.Spacing.small)
            }
            modelStatus
            Button("Open a File…") {
                model.introduction.finish()
                model.presentOpenPanel()
            }
            .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .regular))
            .axLeaf("Introduction.Button.OpenFile")
            .padding(.top, DS.Spacing.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            model.capturePermissions.refresh()
            model.dictationPermissions.refresh()
        }
    }

    @ViewBuilder
    private func permissionRow(_ kind: PermissionKind, isFirst: Bool) -> some View {
        switch kind {
        case .microphone:
            PermissionRow(
                title: String(localized: "Microphone"),
                detail: String(localized: "Captures your voice for recordings and dictation."),
                granted: model.dictationPermissions.microphoneAuthorized,
                isFirst: isFirst,
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
            PermissionRow(
                title: String(localized: "System Audio Recording"),
                detail: String(localized: "Records meetings and anything else your Mac plays."),
                granted: model.capturePermissions.systemAudioGranted,
                isFirst: isFirst,
                axID: "Introduction.Button.GrantSystemAudio",
                action: { model.capturePermissions.requestSystemAudio() },
                actionLabel: String(localized: "Allow…")
            )
        case .accessibility:
            PermissionRow(
                title: String(localized: "Accessibility"),
                detail: String(localized: "Watches for the dictation hotkey and inserts text where you type."),
                granted: model.dictationPermissions.accessibilityGranted,
                isFirst: isFirst,
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
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text("\(AppModel.modelLabel(name)) keeps downloading in the background.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                DSProgressBar(value: progress)
                    .frame(width: 280)
            }
            .padding(.top, DS.Spacing.small)
        case .failed(let message):
            Text(message)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.dangerText)
                .padding(.top, DS.Spacing.small)
        default:
            EmptyView()
        }
    }
}
