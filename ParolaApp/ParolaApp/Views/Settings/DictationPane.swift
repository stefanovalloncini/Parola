import SwiftUI
import ParolaCore
import ParolaDictation

struct DictationPane: View {
    @Environment(AppModel.self) private var model
    @State private var customApps: [(bundleID: String, name: String)] = []

    private var currentModeName: String? {
        AppModel.dictationCleanupModeName(for: model.dictationCleanupPromptID)
    }

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 16) {
            DictationHUDPreview(
                style: model.dictationIndicatorStyle,
                modeName: currentModeName
            )
            SettingsSection("Permissions") {
                PermissionRow(
                    title: String(localized: "Accessibility"),
                    detail: String(localized: "Watches the hotkey outside Parola, inserts the text, and positions the indicator."),
                    granted: model.dictationPermissions.accessibilityGranted,
                    isFirst: true,
                    axID: "Dictation.Button.GrantAccessibility",
                    action: { model.dictationPermissions.openAccessibilitySettings() },
                    actionLabel: String(localized: "Open System Settings…")
                )
                PermissionRow(
                    title: String(localized: "Microphone"),
                    detail: String(localized: "Captures your voice while dictating."),
                    granted: model.dictationPermissions.microphoneAuthorized,
                    isFirst: false,
                    axID: "Dictation.Button.GrantMicrophone",
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
            SettingsSection {
                SettingRow("Enable dictation",
                           descriptionVerbatim: modeDescription,
                           isFirst: true) {
                    Toggle("", isOn: $model.dictationEnabled).labelsHidden()
                        .axLeaf("Dictation.Toggle.Enabled")
                }
                SettingRow("Mode") {
                    Picker("", selection: $model.dictationModeRaw) {
                        ForEach(DictationMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .axLeaf("Dictation.Picker.Mode")
                }
                SettingRow("Activation key",
                           descriptionVerbatim: activationDescription) {
                    HotkeyRecorder(
                        keyCode: $model.dictationKeyCode,
                        modifierRawValue: $model.dictationKeyModifiers
                    )
                }
                SettingRow("Indicator style",
                           descriptionVerbatim: model.dictationIndicatorStyle.description) {
                    Picker("", selection: $model.dictationIndicatorStyleRaw) {
                        ForEach(DictationIndicatorStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .axLeaf("Dictation.Picker.IndicatorStyle")
                }
                SettingRow("HUD opacity",
                           description: "Make the dictation HUD translucent.") {
                    HStack(spacing: 8) {
                        Slider(value: $model.dictationHudOpacity, in: 0.4...1.0)
                            .frame(width: 160)
                            .axLeaf("Dictation.Slider.HudOpacity")
                        Text("\(Int(model.dictationHudOpacity * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                SettingRow("Cleanup style",
                           description: "Voice inserts the transcript as spoken; the other styles rewrite it with the on-device model.") {
                    DictationModeRow(selectedID: $model.dictationCleanupPromptID)
                }
                SettingRow("Strip self-corrections",
                           description: "Drops \"scratch that\", \"wait, no\", and collapses \", I mean,\" hedges.") {
                    Toggle("", isOn: $model.dictationStripSelfCorrections).labelsHidden()
                        .axLeaf("Dictation.Toggle.StripSelfCorrections")
                }
                SettingRow("Paste delay",
                           description: "Wait this long after dictation ends before pasting. Useful when the target app needs a beat to refocus.") {
                    HStack(spacing: 6) {
                        Slider(value: pasteDelayBinding, in: 0...1000, step: 50)
                            .frame(width: 160)
                            .axLeaf("Dictation.Slider.PasteDelay")
                        Text("\(model.dictationPasteDelayMs) ms")
                            .font(DS.Font.subheadlineMono)
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
            SettingHelper(text: "Needs Accessibility to watch the hotkey outside Parola, insert text, and position the indicator near the field. The HUD shows a live waveform while you speak.")

            SettingsSection("Context (optional)") {
                SettingRow("Include selected text",
                           description: "Sends the highlighted text in the frontmost app to the cleanup model so proper nouns spell right. Requires Accessibility permission.",
                           isFirst: true) {
                    Toggle("", isOn: $model.dictationContextSelection).labelsHidden()
                        .axLeaf("Dictation.Toggle.ContextSelection")
                }
                SettingRow("Include clipboard",
                           description: "Adds the current clipboard string. Disable when the clipboard might hold sensitive data.") {
                    Toggle("", isOn: $model.dictationContextClipboard).labelsHidden()
                        .axLeaf("Dictation.Toggle.ContextClipboard")
                }
                SettingRow("Include screen content (OCR)",
                           description: "Reads on-screen text in the frontmost window via OCR. Slower, requires Screen Recording permission, and the window content is sent to the cleanup model.") {
                    Toggle("", isOn: $model.dictationContextScreen).labelsHidden()
                        .axLeaf("Dictation.Toggle.ContextScreen")
                }
            }
            SettingHelper(text: "Context reaches the cleanup model only when a style other than Voice runs, to help spell proper nouns and technical terms. All three are off by default.")

            SettingsSection("Per-app workflows") {
                let seeds = AppModel.dictationOverrideApps
                ForEach(Array(seeds.enumerated()), id: \.element.bundleID) { idx, app in
                    WorkflowRow(app: app, isFirst: idx == 0, isRemovable: false)
                }
                ForEach(Array(customApps.enumerated()), id: \.element.bundleID) { _, app in
                    WorkflowRow(app: app, isFirst: false, isRemovable: true)
                }
            }
            HStack {
                Button {
                    model.presentAddDictationAppPanel()
                    customApps = model.customDictationOverrideApps()
                } label: {
                    Label("Add app…", systemImage: "plus.circle")
                }
                .axLeaf("Dictation.Button.AddApp")
                Spacer()
            }
            SettingHelper(text: "When the frontmost app matches, dictation uses these overrides. Prompt cleans up the text after transcription; language hints the engine before it. In supported browsers, URL rules win over the app's own row.")
            ResetPaneButton(scope: .dictation)
        }
        .onAppear {
            customApps = model.customDictationOverrideApps()
            model.dictationPermissions.refresh()
        }
        .onChange(of: model.dictationPerAppOverridesJSON) { _, _ in
            customApps = model.customDictationOverrideApps()
        }
    }

    private var modeDescription: String {
        model.dictationMode.description + " " + String(localized: "While enabled, a mic icon in the menu bar starts and stops dictation.")
    }

    private var activationDescription: String {
        var text = String(localized: "Click to record any key combination.")
        if model.dictationModifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            text += " " + String(localized: "Bare F-keys reach Parola only when pressed with Fn, unless \"Use F1, F2… as standard function keys\" is on.")
        }
        return text
    }

    private var pasteDelayBinding: Binding<Double> {
        Binding(
            get: { Double(model.dictationPasteDelayMs) },
            set: { model.dictationPasteDelayMs = Int($0) }
        )
    }
}

private struct PermissionRow: View {
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
                    .fill(granted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(granted ? String(localized: "Granted") : String(localized: "Not granted"))
                    .font(DS.Font.caption2Medium)
                    .foregroundStyle(.secondary)
                if !granted {
                    Button(actionLabel, action: action)
                        .axLeaf(axID)
                }
            }
        }
    }
}
