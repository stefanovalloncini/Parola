import SwiftUI
import ParolaCore

struct DictationPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection {
                SettingRow("Enable dictation",
                           description: "Hold F5 to dictate; release to paste the text at the cursor.",
                           isFirst: true) {
                    Toggle("", isOn: $model.dictationEnabled).labelsHidden()
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
            SettingHelper(text: "Press and hold the dictation key to dictate. Requires Input Monitoring permission.")

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
}
