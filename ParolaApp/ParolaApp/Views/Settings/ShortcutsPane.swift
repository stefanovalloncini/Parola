import SwiftUI
import ParolaCore

struct ShortcutsPane: View {
    var body: some View {
        SettingsSection {
            SettingRow("Open Audio…", isFirst: true) { Text("⌘O").foregroundStyle(.secondary) }
            SettingRow("Save Document") { Text("⌘S").foregroundStyle(.secondary) }
            SettingRow("Find") { Text("⌘F").foregroundStyle(.secondary) }
            SettingRow("Toggle Live Captions") { Text("⇧⌘L").foregroundStyle(.secondary) }
            SettingRow("Export as TXT") { Text("⌘E").foregroundStyle(.secondary) }
            SettingRow("Dictation hotkey") { Text("F5").foregroundStyle(.secondary) }
        }
    }
}
