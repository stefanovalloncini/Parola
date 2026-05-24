import SwiftUI
import ParolaCore

struct LiveCaptionsPane: View {
    @Environment(LiveCaptionsController.self) private var liveCaptions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Translate to English",
                           description: "Translate captions live as you speak.",
                           isFirst: true) {
                    Toggle("", isOn: translateBinding)
                        .labelsHidden()
                        .axLeaf("LiveCaptions.Toggle.Translate")
                }
                SettingRow("Status") {
                    Text(liveCaptions.isActive ? "Running" : "Stopped")
                        .foregroundStyle(.secondary)
                }
            }
            SettingHelper(text: "Start and stop live captions from the Captions menu (⇧⌘L).")
            ResetPaneButton(scope: .liveCaptions)
        }
    }

    private var translateBinding: Binding<Bool> {
        Binding(
            get: { liveCaptions.translateToEnglish },
            set: { newValue in
                Task { await liveCaptions.setTranslate(newValue) }
            }
        )
    }
}
