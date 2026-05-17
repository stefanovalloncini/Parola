import SwiftUI
import ParolaCore

struct DictationPane: View {
    @EnvironmentObject var model: AppModel

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
                SettingRow("Activation key") {
                    Picker("", selection: $model.dictationKeyCode) {
                        ForEach(DictationHotkey.allCases, id: \.rawValue) { key in
                            Text(key.displayName).tag(key.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
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

            SettingsSection("Per-app overrides") {
                let apps = AppModel.dictationOverrideApps
                ForEach(Array(apps.enumerated()), id: \.element.bundleID) { idx, app in
                    SettingRow(app.name, isFirst: idx == 0) {
                        Picker("", selection: Binding(
                            get: { model.dictationOverridePromptID(for: app.bundleID) },
                            set: { model.setDictationOverridePromptID($0, for: app.bundleID) }
                        )) {
                            Text("Use default").tag("")
                            ForEach(Prompt.builtIns) { prompt in
                                Text(prompt.name).tag(prompt.id.uuidString)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }
                }
            }
            SettingHelper(text: "Override the default cleanup mode when the frontmost app matches.")
        }
    }

    private var modeDescription: String {
        model.dictationMode.description
    }
}
