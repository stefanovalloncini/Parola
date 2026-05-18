import SwiftUI
import ParolaCore

struct CustomizationPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                SettingRow("Accent color",
                           description: "Used for the active sidebar item, primary buttons, and other highlights.") {
                    AccentColorRow(selection: $model.appAccentRaw)
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
            ResetPaneButton(scope: .customization)
        }
    }
}

private struct AccentColorRow: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppAccent.allCases) { accent in
                Button {
                    selection = accent.rawValue
                } label: {
                    ZStack {
                        Circle()
                            .fill(accent.color)
                            .frame(width: 22, height: 22)
                        if accent.rawValue == selection {
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.6), lineWidth: 2)
                                .frame(width: 26, height: 26)
                        }
                    }
                    .padding(2)
                }
                .buttonStyle(.plain)
                .help(accent.label)
            }
        }
    }
}
