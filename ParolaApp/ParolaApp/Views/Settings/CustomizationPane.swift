import SwiftUI
import ParolaCore

struct CustomizationPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsSection {
            SettingRow("Appearance", isFirst: true) {
                Picker("", selection: $model.appTheme) {
                    Text("Match system").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }
            SettingRow("Monospaced timestamps",
                       description: "Use a fixed-width font for timestamps in the transcript.") {
                Toggle("", isOn: $model.monospacedTimestamps).labelsHidden()
            }
            SettingRow("Sidebar density",
                       description: "Spacing in the library sidebar.") {
                Picker("", selection: $model.sidebarDensity) {
                    Text("Comfortable").tag("comfortable")
                    Text("Compact").tag("compact")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }
        }
    }
}
