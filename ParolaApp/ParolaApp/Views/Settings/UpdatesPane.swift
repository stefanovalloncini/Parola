import SwiftUI

struct UpdatesPane: View {
    @Environment(AppModel.self) private var model
    @State private var feedConfigured: Bool = SparkleUpdater.shared.feedURLConfigured

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Check automatically",
                           description: "Looks for updates in the background once a day.",
                           isFirst: true) {
                    Toggle("", isOn: $model.sparkleAutomatic).labelsHidden()
                        .axLeaf("Updates.Toggle.Automatic")
                }
                SettingRow("Channel", description: model.sparkleChannel.description) {
                    Picker("", selection: $model.sparkleChannelRaw) {
                        ForEach(SparkleChannel.allCases) { c in
                            Text(c.displayName).tag(c.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .axLeaf("Updates.Picker.Channel")
                }
                SettingRow("Check now") {
                    Button("Check for updates…") {
                        SparkleUpdater.shared.checkForUpdates()
                    }
                    .disabled(!feedConfigured)
                    .axLeaf("Updates.Button.CheckNow")
                }
            }

            if !feedConfigured {
                SettingsSection {
                    SettingRow("Update feed",
                               description: "An appcast URL hasn't been configured yet, so checks won't run.",
                               isFirst: true) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.Palette.warning)
                    }
                }
                SettingHelper(text: "Set the SUFeedURL and SUPublicEDKey keys in Info.plist before shipping. Generate the keypair once with Sparkle's generate_keys tool.")
            } else {
                SettingHelper(text: "Updates are signed and verified with Sparkle's EdDSA keys before installation.")
            }
            ResetPaneButton(scope: .updates)
        }
        .onAppear {
            feedConfigured = SparkleUpdater.shared.feedURLConfigured
        }
    }
}
