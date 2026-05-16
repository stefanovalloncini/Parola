import SwiftUI
import ParolaCore

struct MicrophonePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Microphone Mode",
                           description: "Always use the system's default microphone.",
                           isFirst: true) {
                    Text("System Default").foregroundStyle(.secondary)
                }
            }
            SettingHelper(text: "Change the default microphone in System Settings › Sound.")
        }
    }
}
