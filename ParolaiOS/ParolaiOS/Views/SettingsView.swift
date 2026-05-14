import SwiftUI
import ParolaCore

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var model: AppModel
    @State private var confirmingReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Model", selection: $model.settings.modelName) {
                        ForEach(model.availableModels) { entry in
                            Text(entry.label).tag(entry.name)
                        }
                    }
                    NavigationLink {
                        LanguagePicker(selection: $model.settings.language, compact: false)
                            .navigationTitle(Text("language.choose"))
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack {
                            Text("Language")
                            Spacer()
                            Text(LanguageCatalog.label(for: model.settings.language))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Translate to English", isOn: $model.settings.translate)
                    Toggle("Word timestamps", isOn: $model.settings.wordTimestamps)
                } header: {
                    Text("Active model")
                } footer: {
                    Text("Word timestamps power playback highlighting.")
                }

                Section("Custom vocabulary") {
                    TextField(
                        "Names or jargon, comma-separated",
                        text: $model.settings.initialPrompt,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                }

                Section("Models on device") {
                    ForEach(model.availableModels) { entry in
                        modelRow(entry)
                    }
                }

                Section {
                    Button {
                        confirmingReset = true
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Show welcome screens again")
                        }
                    }
                }

                Section {
                    Text("Parola — on-device speech-to-text.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                Text("Show welcome screens again?"),
                isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("Show next time", role: .none) {
                    model.settings.onboardingComplete = false
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They'll appear the next time you open Parola.")
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ entry: ModelInfo) -> some View {
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

    private func humanBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes); var idx = 0
        while value >= 1024, idx < units.count - 1 { value /= 1024; idx += 1 }
        return String(format: "%.1f %@", value, units[idx])
    }
}
