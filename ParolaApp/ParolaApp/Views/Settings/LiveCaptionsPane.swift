import SwiftUI
import ParolaCore

struct LiveCaptionsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(LiveCaptionsController.self) private var liveCaptions

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Live captions transcribe the microphone as you speak and show the words in a floating panel that stays above other windows.")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            SettingsSection {
                SettingRow("Translate to English",
                           description: "Translate captions live as you speak.",
                           isFirst: true) {
                    Toggle("", isOn: $model.liveCaptionsTranslate)
                        .labelsHidden()
                        .axLeaf("LiveCaptions.Toggle.Translate")
                }
                if let warning = model.translateMismatchWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.warningText)
                        .padding(.top, DS.Spacing.hair)
                        .axLeaf("LiveCaptions.Label.TranslateWarning")
                }
                SettingRow("Status",
                           description: "Whether captions are running right now.") {
                    Text(liveCaptions.isActive ? "Running" : "Stopped")
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
            SettingHelper(text: "Start and stop live captions from the Captions menu (⇧⌘L).")
            ResetPaneButton(scope: .liveCaptions)
        }
    }
}
