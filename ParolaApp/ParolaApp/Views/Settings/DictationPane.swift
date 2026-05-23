import SwiftUI
import ParolaCore

struct DictationPane: View {
    @EnvironmentObject var model: AppModel
    @State private var customApps: [(bundleID: String, name: String)] = []

    private var currentModeName: String? {
        let id = model.dictationCleanupPromptID
        if id.isEmpty {
            return DictationModePreset.builtIns.first { $0.promptID == nil }?.name
        }
        guard let uuid = UUID(uuidString: id) else { return nil }
        if let preset = DictationModePreset.builtIns.first(where: { $0.promptID == uuid }) {
            return preset.name
        }
        return Prompt.builtIns.first(where: { $0.id == uuid })?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DictationHUDPreview(
                style: model.dictationIndicatorStyle,
                modeName: currentModeName
            )
            SettingsSection {
                SettingRow("Enable dictation",
                           descriptionVerbatim: modeDescription,
                           isFirst: true) {
                    Toggle("", isOn: $model.dictationEnabled).labelsHidden()
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
                }
                SettingRow("Activation key",
                           description: "Click to record any key combination.") {
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
                }
                SettingRow("HUD opacity",
                           description: "Make the dictation HUD translucent.") {
                    HStack(spacing: 8) {
                        Slider(value: $model.dictationHudOpacity, in: 0.4...1.0)
                            .frame(width: 160)
                        Text("\(Int(model.dictationHudOpacity * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                SettingRow("Mode",
                           description: "Quick context: how the dictated text should land.") {
                    DictationModeRow(selectedID: $model.dictationCleanupPromptID)
                }
                SettingRow("Rewrite preset",
                           description: "Fine-tune the cleanup tone.") {
                    RewritePresetRow(selectedID: $model.dictationCleanupPromptID)
                }
                SettingRow("Cleanup mode") {
                    Picker("", selection: $model.dictationCleanupPromptID) {
                        Text("Raw (no cleanup)").tag("")
                        ForEach(Prompt.builtIns) { prompt in
                            Text(prompt.name).tag(prompt.id.uuidString)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
                SettingRow("Strip self-corrections",
                           description: "Drops \"scratch that\", \"wait, no\", and collapses \", I mean,\" hedges.") {
                    Toggle("", isOn: $model.dictationStripSelfCorrections).labelsHidden()
                }
                SettingRow("Paste delay",
                           description: "Wait this long after dictation ends before pasting. Useful when the target app needs a beat to refocus.") {
                    HStack(spacing: 6) {
                        Slider(value: Binding(
                            get: { Double(model.dictationPasteDelayMs) },
                            set: { model.dictationPasteDelayMs = Int($0) }
                        ), in: 0...1000, step: 50)
                        .frame(width: 160)
                        Text("\(model.dictationPasteDelayMs) ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
            SettingHelper(text: "Requires Input Monitoring permission. The HUD shows a live waveform while you speak.")

            SettingsSection("Context (optional)") {
                SettingRow("Include selected text",
                           description: "Sends the highlighted text in the frontmost app to the cleanup model so proper nouns spell right. Requires Accessibility permission.",
                           isFirst: true) {
                    Toggle("", isOn: $model.dictationContextSelection).labelsHidden()
                }
                SettingRow("Include clipboard",
                           description: "Adds the current clipboard string. Disable when the clipboard might hold sensitive data.") {
                    Toggle("", isOn: $model.dictationContextClipboard).labelsHidden()
                }
                SettingRow("Include screen content (OCR)",
                           description: "Reads on-screen text in the frontmost window via OCR. Slower, requires Screen Recording permission, and the window content is sent to the cleanup model.") {
                    Toggle("", isOn: $model.dictationContextScreen).labelsHidden()
                }
            }
            SettingHelper(text: "Context is used only for proper nouns and technical terms — the model never echoes or responds to it. All three are off by default.")

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
                Spacer()
            }
            SettingHelper(text: "When the frontmost app matches, dictation uses these overrides. Prompt cleans up the text after transcription; language hints the engine before it. URL rules take precedence over the bundle default for supported browsers.")
            ResetPaneButton(scope: .dictation)
        }
        .onAppear {
            customApps = model.customDictationOverrideApps()
        }
        .onChange(of: model.dictationPerAppOverridesJSON) { _, _ in
            customApps = model.customDictationOverrideApps()
        }
    }

    private var modeDescription: String {
        model.dictationMode.description
    }
}
