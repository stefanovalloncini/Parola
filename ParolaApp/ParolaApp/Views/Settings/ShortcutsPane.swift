import SwiftUI
import ParolaCore

struct ShortcutsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection("Menu equivalents") {
                SettingRow("Open Audio…", isFirst: true) { Text("⌘O").foregroundStyle(.secondary) }
                SettingRow("Save Document") { Text("⌘S").foregroundStyle(.secondary) }
                SettingRow("Find") { Text("⌘F").foregroundStyle(.secondary) }
                SettingRow("Toggle Live Captions") { Text("⇧⌘L").foregroundStyle(.secondary) }
                SettingRow("Export as TXT") { Text("⌘E").foregroundStyle(.secondary) }
            }
            SettingsSection("Customizable") {
                SettingRow("Dictation hotkey",
                           description: "Same control as the Dictation pane. Records any key combo.",
                           isFirst: true) {
                    HotkeyRecorder(
                        keyCode: $model.dictationKeyCode,
                        modifierRawValue: $model.dictationKeyModifiers
                    )
                }
            }
            SettingHelper(text: "Menu equivalents are fixed. Dictation needs Input Monitoring permission.")
        }
    }
}
