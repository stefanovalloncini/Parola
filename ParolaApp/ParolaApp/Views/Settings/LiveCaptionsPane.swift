import SwiftUI
import ParolaCore

struct LiveCaptionsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(LiveCaptionsController.self) private var liveCaptions

    var body: some View {
        @Bindable var model = model
        SettingsForm {
            Section {
                SettingRow("Live captions",
                           descriptionVerbatim: model.liveCaptionsUnavailableReason ?? String(localized: "Also in the Captions menu (⇧⌘L).")) {
                    Button(liveCaptions.isActive ? "Stop Live Captions" : "Start Live Captions") {
                        model.toggleLiveCaptions()
                    }
                    .disabled(!liveCaptions.isActive && model.liveCaptionsUnavailableReason != nil)
                    .axLeaf("LiveCaptions.Button.StartStop")
                }
                SettingRow("Translate to English",
                           description: "Translate captions live as you speak.") {
                    Toggle("", isOn: $model.liveCaptionsTranslate)
                        .labelsHidden()
                        .axLeaf("LiveCaptions.Toggle.Translate")
                }
            } footer: {
                VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                    if let warning = model.translateMismatchWarning {
                        SettingsWarning(warning)
                            .axLeaf("LiveCaptions.Label.TranslateWarning")
                    }
                    Text("Live captions transcribe the microphone as you speak and show the words in a floating panel that stays above other windows.")
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            ResetPaneButton(scope: .liveCaptions)
        }
    }
}
