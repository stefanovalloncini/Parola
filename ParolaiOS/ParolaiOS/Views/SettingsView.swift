import SwiftUI
import ParolaCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Active model") {
                    Picker("Model", selection: $model.selectedModel) {
                        ForEach(model.availableModels) { entry in
                            Text(entry.label).tag(entry.name)
                        }
                    }
                    Toggle("Translate to English", isOn: $model.translate)
                    Toggle("Word timestamps", isOn: $model.wordTimestamps)
                }
                Section("Custom vocabulary") {
                    TextField("Names or jargon, comma-separated", text: $model.initialPrompt, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section("Models on device") {
                    ForEach(model.availableModels) { entry in
                        HStack {
                            Image(systemName: entry.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(entry.isInstalled ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.label)
                                if let size = entry.approximateSizeBytes {
                                    Text(humanBytes(size))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if entry.isInstalled {
                                Button(role: .destructive) {
                                    model.deleteModel(entry.name)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("Parola \(Parola.version) — on-device speech-to-text.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func humanBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes); var idx = 0
        while value >= 1024, idx < units.count - 1 { value /= 1024; idx += 1 }
        return String(format: "%.1f %@", value, units[idx])
    }
}
