import SwiftUI
import ParolaCore

struct LiveCaptionsPane: View {
    @EnvironmentObject var liveCaptions: LiveCaptionsController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Translate to English",
                           description: "Translate captions live as you speak.",
                           isFirst: true) {
                    Toggle("", isOn: Binding(
                        get: { liveCaptions.translateToEnglish },
                        set: { newValue in
                            Task { await liveCaptions.setTranslate(newValue) }
                        }
                    ))
                    .labelsHidden()
                }
                SettingRow("Status") {
                    Text(liveCaptions.isActive ? "Running" : "Stopped")
                        .foregroundStyle(.secondary)
                }
            }
            SettingHelper(text: "Start and stop live captions from the Captions menu (⇧⌘L).")
        }
    }
}
