import SwiftUI
import ParolaCore

struct ServicesPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("On-device language model",
                           description: "Uses Apple's on-device foundation model when available.",
                           isFirst: true) {
                    Text("Built-in").foregroundStyle(.secondary)
                }
                SettingRow("Cloud providers",
                           description: "Bring-your-own-key support is configured in the main window.") {
                    Text("BYOK").foregroundStyle(.secondary)
                }
            }
            SettingHelper(text: "API keys are stored in the macOS keychain.")
        }
    }
}
