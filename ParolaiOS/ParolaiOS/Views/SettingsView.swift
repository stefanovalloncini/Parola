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
                    Picker("settings.model", selection: $model.settings.modelName) {
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
                            Text("settings.language")
                            Spacer()
                            Text(LanguageCatalog.label(for: model.settings.language))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("settings.translate", isOn: $model.settings.translate)
                    Toggle("settings.wordTimestamps", isOn: $model.settings.wordTimestamps)
                } header: {
                    Text("settings.section.activeModel")
                } footer: {
                    Text("settings.wordTimestamps.footer")
                }

                Section("settings.vocabulary.title") {
                    TextField(
                        "settings.vocabulary.placeholder",
                        text: $model.settings.initialPrompt,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                }

                Section("settings.modelsOnDevice") {
                    ForEach(model.availableModels) { entry in
                        modelRow(entry)
                    }
                }

                Section {
                    NavigationLink {
                        AutoExportSettings()
                            .environmentObject(model)
                            .navigationTitle("Auto-Export")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Auto-Export")
                            Spacer()
                            Text("\(model.autoExportRules.filter(\.enabled).count) active")
                                .foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        IgnoredSegmentsSettings()
                            .environmentObject(model)
                            .navigationTitle("Filters")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text("Ignored Segments")
                            Spacer()
                            Text("\(model.ignoredSegmentRules.filter(\.enabled).count) active")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        confirmingReset = true
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("settings.showWelcomeAgain")
                        }
                    }
                }

                Section {
                    Text("settings.about")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("settings.title")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                Text("settings.showWelcomeAgain.confirm"),
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
        Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .file))
    }
}
