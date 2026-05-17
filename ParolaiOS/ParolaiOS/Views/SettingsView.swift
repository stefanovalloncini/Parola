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
                    .onChange(of: model.settings.modelName) {
                        if isEnglishOnlyModel { model.settings.language = "en" }
                        if !supportsTranslate { model.settings.translate = false }
                    }
                    if isEnglishOnlyModel {
                        HStack {
                            Text("settings.language")
                            Spacer()
                            Text("English").foregroundStyle(.secondary)
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
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
                    }
                    if supportsTranslate {
                        Toggle("settings.translate", isOn: $model.settings.translate)
                    }
                    Toggle("settings.wordTimestamps", isOn: $model.settings.wordTimestamps)
                } header: {
                    Text("settings.section.activeModel")
                } footer: {
                    if isEnglishOnlyModel {
                        Text("This model is English-only. Pick a multilingual model to transcribe other languages.")
                    } else {
                        Text("settings.wordTimestamps.footer")
                    }
                }

                if supportsInitialPrompt {
                    Section("settings.vocabulary.title") {
                        TextField(
                            "settings.vocabulary.placeholder",
                            text: $model.settings.initialPrompt,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                    }
                }

                Section {
                    NavigationLink {
                        ModelManagerView()
                            .environmentObject(model)
                    } label: {
                        HStack {
                            Image(systemName: "internaldrive")
                            Text("settings.modelsOnDevice")
                            Spacer()
                            Text("\(installedCount)/\(model.availableModels.count)")
                                .foregroundStyle(.secondary)
                        }
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
                    NavigationLink {
                        FindReplaceSettings()
                            .environmentObject(model)
                            .navigationTitle("Find & Replace")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Find & Replace")
                            Spacer()
                            Text("\(model.findReplaceRules.filter(\.enabled).count) active")
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

    private var capabilities: EngineCapabilities {
        ModelCatalog.staticCapabilities(forID: model.settings.modelName)
            ?? .whisperKitDefaults
    }

    private var isEnglishOnlyModel: Bool {
        capabilities.supportedLanguages.isEnglishOnly
    }

    private var supportsTranslate: Bool { capabilities.supportsTranslate }
    private var supportsInitialPrompt: Bool { capabilities.supportsInitialPrompt }

    private var installedCount: Int {
        model.availableModels.filter(\.isInstalled).count
    }
}
