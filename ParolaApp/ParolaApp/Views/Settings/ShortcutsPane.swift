import SwiftUI
import ParolaCore

struct ShortcutsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return SettingsForm {
            SettingsSection {
                SettingRow("Dictation shortcut",
                           description: "Starts dictation from any app. The Dictation pane shows the same shortcut.") {
                    HotkeyRecorder(
                        keyCode: $model.dictationKeyCode,
                        modifierRawValue: $model.dictationKeyModifiers
                    )
                }
                SettingRow("Recording shortcut",
                           description: "Starts or stops a microphone recording from any app. Off by default.") {
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
            SettingsSection {
                PermissionRow(
                    title: String(localized: "Accessibility"),
                    detail: String(localized: "Lets these shortcuts work while another app is in front."),
                    granted: model.dictationPermissions.accessibilityGranted,
                    axID: "Shortcuts.Button.GrantAccessibility",
                    action: { model.dictationPermissions.openAccessibilitySettings() },
                    actionLabel: String(localized: "Open System Settings…")
                )
            }
            SettingHelper(text: "Every menu shortcut is listed under Help ▸ Keyboard Shortcuts.")
            ResetPaneButton(scope: .shortcuts)
        }
    }
}
