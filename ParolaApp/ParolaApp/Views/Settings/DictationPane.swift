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
        return SettingsForm {
            SettingsSection {
                SettingRow("Enable dictation",
                           descriptionVerbatim: enableDescription,
                           isFirst: true) {
                    Toggle("", isOn: $model.dictationEnabled).labelsHidden()
                        .axLeaf("Dictation.Toggle.Enabled")
                }
            }
            DictationPermissionsSection(permissions: model.dictationPermissions)
            Group {
                settings
            }
            .disabled(!model.dictationEnabled)
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

    @ViewBuilder
    private var settings: some View {
        @Bindable var model = model
        DictationHUDPreview(
            style: model.dictationIndicatorStyle,
            modeName: currentModeName
        )
        SettingsSection {
            SettingRow("Mode",
                       descriptionVerbatim: model.dictationMode.description,
                       isFirst: true) {
                Picker("", selection: $model.dictationModeRaw) {
                    ForEach(DictationMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200, alignment: .trailing)
                .axLeaf("Dictation.Picker.Mode")
            }
            SettingRow("Model",
                       description: "Dictation uses the model set in Transcription Defaults or on the Library page.") {
                HStack(spacing: 8) {
                    Text(AppModel.modelLabel(model.selectedModel))
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .axLeaf("Dictation.Label.Model")
                    Button("Change…") {
                        model.settingsPane = SettingsRoute.transcriptionDefaults.rawValue
                    }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Dictation.Button.ChangeModel")
                }
            }
            ForEach(model.dictationModelWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.warningText)
                    .padding(.horizontal, DS.Spacing.regular)
                    .padding(.vertical, DS.Spacing.tight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .axLeaf("Dictation.Label.ModelWarning")
            }
            SettingRow("Activation key",
                       descriptionVerbatim: activationDescription) {
                // Paused while recording: the armed dictation monitor sees the recorded
                // keystroke first and would start a session the rebind then tears down mid-flight.
                HotkeyRecorder(
                    keyCode: $model.dictationKeyCode,
                    modifierRawValue: $model.dictationKeyModifiers,
                    onRecordingChanged: { recording in
                        if recording {
                            model.abortDictation()
                        } else if model.dictationEnabled {
                            model.startDictation()
                        }
                    }
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
                .frame(width: 200, alignment: .trailing)
                .axLeaf("Dictation.Picker.IndicatorStyle")
            }
            SettingRow("HUD opacity",
                       description: "Make the dictation HUD translucent.") {
                HStack(spacing: 8) {
                    Slider(value: $model.dictationHudOpacity, in: 0.4...1.0)
                        .frame(width: 160)
                        .axLeaf("Dictation.Slider.HudOpacity")
                    Text(AppFormat.percent(model.dictationHudOpacity))
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Color.secondaryText)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            SettingRow("Cleanup style",
                       description: "Voice inserts the transcript as spoken; the other styles rewrite it with the on-device model.") {
                DictationModeRow(selectedID: $model.dictationCleanupPromptID)
            }
            SettingRow("Strip self-corrections",
                       description: "Drops “scratch that”, “wait, no”, and collapses “, I mean,” hedges.") {
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
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Color.secondaryText)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
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
                Label("Add App…", systemImage: "plus.circle")
            }
            .axLeaf("Dictation.Button.AddApp")
            Spacer()
        }
        SettingHelper(text: "When the frontmost app matches, dictation uses these overrides. Prompt cleans up the text after transcription; language hints the engine before it. In supported browsers, URL rules win over the app's own row.")
    }

    private var enableDescription: String {
        String(localized: "Arms the activation key so you can dictate into any app. A mic icon in the menu bar also starts and stops it.")
    }

    private var isBareFunctionKey: Bool {
        guard model.dictationModifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
        let name = HotkeyDisplay.keyName(forKeyCode: model.dictationKeyCode)
        return name.count >= 2 && name.first == "F" && name.dropFirst().allSatisfy(\.isNumber)
    }

    private var activationDescription: String {
        var text = String(localized: "Click to record any key combination.")
        if isBareFunctionKey {
            text += " " + String(localized: "Bare F-keys need Fn unless “standard function keys” is on in Keyboard settings.")
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

struct DictationPermissionsSection: View {
    let permissions: DictationPermissions

    var body: some View {
        if !(permissions.accessibilityGranted && permissions.microphoneAuthorized) {
            section
        }
    }

    private var section: some View {
        SettingsSection("Permissions") {
            PermissionRow(
                title: String(localized: "Accessibility"),
                detail: String(localized: "Lets Parola watch the hotkey outside the app and insert text. The near-field indicator also uses it to find your text field."),
                granted: permissions.accessibilityGranted,
                isFirst: true,
                axID: "Dictation.Button.GrantAccessibility",
                action: { permissions.openAccessibilitySettings() },
                actionLabel: String(localized: "Open System Settings…")
            )
            PermissionRow(
                title: String(localized: "Microphone"),
                detail: String(localized: "Captures your voice while dictating."),
                granted: permissions.microphoneAuthorized,
                isFirst: false,
                axID: "Dictation.Button.GrantMicrophone",
                action: {
                    if permissions.microphoneUndetermined {
                        permissions.requestMicrophone()
                    } else {
                        permissions.openMicrophoneSettings()
                    }
                },
                actionLabel: String(localized: "Allow…")
            )
        }
    }
}
