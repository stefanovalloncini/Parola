import SwiftUI
import ParolaCore

struct LiveCaptionsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(LiveCaptionsController.self) private var liveCaptions

    var body: some View {
        @Bindable var model = model
        SettingsForm {
            Text("Live captions transcribe the microphone as you speak and show the words in a floating panel that stays above other windows.")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            SettingsSection {
                SettingRow("Live captions",
                           descriptionVerbatim: model.liveCaptionsUnavailableReason ?? String(localized: "Also in the Captions menu (⇧⌘L)."),
                           isFirst: true) {
                    Button(liveCaptions.isActive ? "Stop Live Captions" : "Start Live Captions") {
                        model.toggleLiveCaptions()
                    }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .disabled(!liveCaptions.isActive && model.liveCaptionsUnavailableReason != nil)
                    .axLeaf("LiveCaptions.Button.StartStop")
                }
                SettingRow("Translate to English",
                           description: "Translate captions live as you speak.") {
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
            }
            ResetPaneButton(scope: .liveCaptions)
        }
    }
}
