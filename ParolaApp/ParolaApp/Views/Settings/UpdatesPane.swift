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
                        .disabled(!feedConfigured)
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
                    .frame(width: 200, alignment: .trailing)
                    .disabled(!feedConfigured)
                    .axLeaf("Updates.Picker.Channel")
                }
                SettingRow("Check now",
                           description: "Looks for a new version straight away.") {
                    Button("Check for Updates…") {
                        SparkleUpdater.shared.checkForUpdates()
                    }
                    .disabled(!feedConfigured)
                    .axLeaf("Updates.Button.CheckNow")
                }
            }

            if !feedConfigured {
                SettingsSection {
                    SettingRow("Update feed",
                               description: "Automatic updates aren't available in this build.",
                               isFirst: true) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.Palette.warning)
                    }
                }
                #if DEBUG
                SettingHelper(text: "Set the SUFeedURL and SUPublicEDKey keys in project.yml before shipping. Generate the keypair once with Sparkle's generate_keys tool.")
                #else
                SettingHelper(text: "New versions are published on the project's GitHub releases page.")
                #endif
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
