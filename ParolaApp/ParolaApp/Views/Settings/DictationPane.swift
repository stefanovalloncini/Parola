import SwiftUI
import ParolaCore

struct DictationPane: View {
    @EnvironmentObject var model: AppModel
    @State private var customApps: [(bundleID: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection {
                SettingRow("Enable dictation",
                           description: modeDescription,
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
                           description: model.dictationIndicatorStyle.description) {
                    Picker("", selection: $model.dictationIndicatorStyleRaw) {
                        ForEach(DictationIndicatorStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
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
            }
            SettingHelper(text: "Requires Input Monitoring permission. The HUD shows a live waveform while you speak.")

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
            SettingHelper(text: "When the frontmost app matches, dictation uses these overrides. Prompt cleans up the text after transcription; language hints the engine before it.")
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

private struct WorkflowRow: View {
    let app: (bundleID: String, name: String)
    let isFirst: Bool
    let isRemovable: Bool
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingRow(app.name, isFirst: isFirst) {
            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { model.dictationOverridePromptID(for: app.bundleID) },
                    set: { model.setDictationOverridePromptID($0, for: app.bundleID) }
                )) {
                    Text("Default prompt").tag("")
                    ForEach(Prompt.builtIns) { prompt in
                        Text(prompt.name).tag(prompt.id.uuidString)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)

                Picker("", selection: Binding(
                    get: { model.dictationOverrideLanguage(for: app.bundleID) },
                    set: { model.setDictationOverrideLanguage($0, for: app.bundleID) }
                )) {
                    Text("Default language").tag("")
                    ForEach(WorkflowLanguageOptions.options, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)

                if isRemovable {
                    Button(role: .destructive) {
                        model.removeDictationOverride(for: app.bundleID)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private enum WorkflowLanguageOptions {
    static let options: [(code: String, name: String)] = [
        ("en", "English"),
        ("it", "Italian"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean")
    ]
}
