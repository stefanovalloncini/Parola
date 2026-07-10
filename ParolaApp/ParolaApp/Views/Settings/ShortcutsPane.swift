import SwiftUI
import ParolaCore

struct ShortcutsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
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
                SettingRow("Mic recording hotkey",
                           description: "Start or stop mic recording from anywhere. Off by default.") {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $model.micHotkeyEnabled).labelsHidden()
                            .axLeaf("Shortcuts.Toggle.MicHotkeyEnabled")
                        HotkeyRecorder(
                            keyCode: $model.micHotkeyKeyCode,
                            modifierRawValue: $model.micHotkeyModifiers
                        )
                        .disabled(!model.micHotkeyEnabled)
                    }
                }
            }
            SettingHelper(text: "Menu equivalents are fixed. Global hotkeys need Input Monitoring permission. The full list is under Help \u{25B8} Keyboard Shortcuts.")
            ResetPaneButton(scope: .shortcuts)
        }
    }
}
