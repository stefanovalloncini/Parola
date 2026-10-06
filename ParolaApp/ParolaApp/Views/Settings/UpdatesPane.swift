import SwiftUI
import AppKit

struct UpdatesPane: View {
    @Environment(AppModel.self) private var model
    @State private var feedConfigured: Bool = SparkleUpdater.shared.feedURLConfigured

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            if feedConfigured {
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
                        .frame(width: 200, alignment: .trailing)
                        .axLeaf("Updates.Picker.Channel")
                    }
                    SettingRow("Check now",
                               description: "Looks for a new version straight away.") {
                        Button("Check for Updates…") {
                            SparkleUpdater.shared.checkForUpdates()
                        }
                        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                        .axLeaf("Updates.Button.CheckNow")
                    }
                }
                SettingHelper(text: "Updates are signed and verified with Sparkle's EdDSA keys before installation.")
                ResetPaneButton(scope: .updates)
            } else {
                SettingsSection {
                    SettingRow("New versions",
                               description: "Automatic updates aren't available in this build.",
                               isFirst: true) {
                        Button("Open Releases Page") {
                            NSWorkspace.shared.open(SupportLinks.releases)
                        }
                        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                        .axLeaf("Updates.Button.Releases")
                    }
                }
                #if DEBUG
                SettingHelper(text: "Set the SUFeedURL and SUPublicEDKey keys in project.yml before shipping. Generate the keypair once with Sparkle's generate_keys tool.")
                #endif
            }
        }
        .onAppear {
            feedConfigured = SparkleUpdater.shared.feedURLConfigured
        }
    }
}
