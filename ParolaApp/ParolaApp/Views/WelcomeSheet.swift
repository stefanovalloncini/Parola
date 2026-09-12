import SwiftUI
import ParolaCore

struct WelcomeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var showsMicrophoneRow: Bool {
        model.features.isEnabled(.micRecording) || model.features.isEnabled(.dictation)
            || model.features.isEnabled(.liveCaptions)
    }

    private var modelDownloadNote: String? {
        let installed = model.availableModels.first(where: { $0.name == model.selectedModel })?.isInstalled ?? false
        guard !installed, let variant = ModelCatalog.variant(id: model.selectedModel) else { return nil }
        let label = AppModel.modelLabel(model.selectedModel)
        let size = AppFormat.byteSize(variant.sizeBytes)
        return String(localized: "No speech model is installed yet — your first transcription downloads \(label) (\(size)).")
    }

    var body: some View {
        SheetFrame(icon: "waveform", title: "Welcome to Parola", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: DS.Spacing.medium) {
                Text("Transcribe files, meetings, and your voice — everything stays on your Mac.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryText)

                SettingsSection {
                    if showsMicrophoneRow {
                        PermissionRow(
                            title: String(localized: "Microphone"),
                            detail: String(localized: "Captures your voice for recordings and dictation."),
                            granted: model.dictationPermissions.microphoneAuthorized,
                            isFirst: true,
                            axID: "Welcome.Button.GrantMicrophone",
                            action: {
                                if model.dictationPermissions.microphoneUndetermined {
                                    model.dictationPermissions.requestMicrophone()
                                } else {
                                    model.dictationPermissions.openMicrophoneSettings()
                                }
                            },
                            actionLabel: String(localized: "Allow…")
                        )
                    }
                    if model.features.isEnabled(.meetings) {
                        PermissionRow(
                            title: String(localized: "System Audio Recording"),
                            detail: String(localized: "Records meetings and anything else your Mac plays."),
                            granted: model.capturePermissions.systemAudioGranted,
                            isFirst: !showsMicrophoneRow,
                            axID: "Welcome.Button.GrantSystemAudio",
                            action: { model.capturePermissions.requestSystemAudio() },
                            actionLabel: String(localized: "Allow…")
                        )
                    }
                    if model.features.isEnabled(.dictation) {
                        PermissionRow(
                            title: String(localized: "Accessibility"),
                            detail: String(localized: "Powers the dictation hotkey and inserts text where you type."),
                            granted: model.dictationPermissions.accessibilityGranted,
                            isFirst: !showsMicrophoneRow && !model.features.isEnabled(.meetings),
                            axID: "Welcome.Button.GrantAccessibility",
                            action: { model.dictationPermissions.openAccessibilitySettings() },
                            actionLabel: String(localized: "Open System Settings…")
                        )
                    }
                }

                Text("Grant each permission the first time you use its feature.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)

                if let modelDownloadNote {
                    Text(modelDownloadNote)
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
            .padding(20)
        } footer: {
            HStack {
                Button("Skip") { dismiss() }
                    .sheetSecondaryAction()
                    .axLeaf("Welcome.Button.Skip")
                Spacer()
                Button("Open a File…") {
                    dismiss()
                    model.presentOpenPanel()
                }
                .sheetPrimaryAction()
                .axLeaf("Welcome.Button.OpenFile")
            }
        }
        .closeLeaf("Welcome.Button.Close")
        .axBranch("Welcome")
    }
}
