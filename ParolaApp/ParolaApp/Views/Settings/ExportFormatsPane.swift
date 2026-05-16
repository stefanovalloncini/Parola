import SwiftUI
import ParolaCore

struct ExportFormatsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                let formats = ExportFormat.allCases
                ForEach(Array(formats.enumerated()), id: \.element) { idx, format in
                    SettingRow(format.rawValue.uppercased(), isFirst: idx == 0) {
                        Text(".\(format.fileExtension)").foregroundStyle(.secondary)
                    }
                }
            }
            SettingHelper(text: "Export the current transcript from the Transcript menu.")
        }
    }
}

struct BatchExportSettingsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Multi-file transcription",
                           description: "Open multiple audio files at once to queue them for batch transcription.",
                           isFirst: true) {
                    Text("Drag & Drop").foregroundStyle(.secondary)
                }
            }
            SettingHelper(text: "Drop a folder of files on the Parola window to start a batch.")
        }
    }
}
