import SwiftUI

struct UpdatesPane: View {
    @AppStorage("sparkleChannel") private var channelRaw: String = SparkleChannel.stable.rawValue
    @AppStorage("sparkleAutomatic") private var automatic: Bool = true
    @State private var feedConfigured: Bool = SparkleUpdater.shared.feedURLConfigured

    private var channel: SparkleChannel {
        SparkleChannel(rawValue: channelRaw) ?? .stable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Check automatically",
                           description: "Looks for updates in the background once a day.",
                           isFirst: true) {
                    Toggle("", isOn: $automatic).labelsHidden()
                        .onChange(of: automatic) { _, newValue in
                            SparkleUpdater.shared.automaticallyChecks = newValue
                        }
                }
                SettingRow("Channel", description: channel.description) {
                    Picker("", selection: $channelRaw) {
                        ForEach(SparkleChannel.allCases) { c in
                            Text(c.displayName).tag(c.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .onChange(of: channelRaw) { _, newValue in
                        if let value = SparkleChannel(rawValue: newValue) {
                            SparkleUpdater.shared.channel = value
                        }
                    }
                }
                SettingRow("Check now") {
                    Button("Check for updates…") {
                        SparkleUpdater.shared.checkForUpdates()
                    }
                    .disabled(!feedConfigured)
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
        }
        .onAppear {
            feedConfigured = SparkleUpdater.shared.feedURLConfigured
            SparkleUpdater.shared.automaticallyChecks = automatic
            if let value = SparkleChannel(rawValue: channelRaw) {
                SparkleUpdater.shared.channel = value
            }
        }
    }
}
