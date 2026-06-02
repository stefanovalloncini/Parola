import SwiftUI
import ParolaCore

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var confirmingReset = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if visibleSections.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    formBody
                }
            }
            .navigationTitle("settings.title")
            .searchable(text: $query, prompt: Text("Search settings"))
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

    private var formBody: some View {
        Form {
            if visibleSections.contains(.activeModel) {
                activeModelSection
            }
            if visibleSections.contains(.appearance) {
                appearanceSection
            }
            if visibleSections.contains(.vocabulary), supportsInitialPrompt {
                vocabularySection
            }
            if visibleSections.contains(.modelsOnDevice) {
                modelsOnDeviceSection
            }
            if visibleSections.contains(.workflows) {
                workflowsSection
            }
            if visibleSections.contains(.welcome) {
                welcomeSection
            }
            if visibleSections.contains(.about) {
                aboutSection
            }
        }
    }

    private var activeModelSection: some View {
        @Bindable var settings = model.settings
        return Section {
            Picker("settings.model", selection: $settings.modelName) {
                ForEach(model.availableModels) { entry in
                    Text(entry.label).tag(entry.name)
                }
            }
            .onChange(of: settings.modelName) {
                if isEnglishOnlyModel { settings.language = "en" }
                if !supportsTranslate { settings.translate = false }
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
                    LanguagePicker(selection: $settings.language, compact: false)
                        .navigationTitle(Text("language.choose"))
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Text("settings.language")
                        Spacer()
                        Text(LanguageCatalog.label(for: settings.language))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if supportsTranslate {
                Toggle("settings.translate", isOn: $settings.translate)
            }
            Toggle("settings.wordTimestamps", isOn: $settings.wordTimestamps)
        } header: {
            Text("settings.section.activeModel")
        } footer: {
            if isEnglishOnlyModel {
                Text("This model is English-only. Pick a multilingual model to transcribe other languages.")
            } else {
                Text("settings.wordTimestamps.footer")
            }
        }
    }

    private var appearanceSection: some View {
        @Bindable var settings = model.settings
        return Section {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        }
    }

    private var vocabularySection: some View {
        @Bindable var settings = model.settings
        return Section("settings.vocabulary.title") {
            TextField(
                "settings.vocabulary.placeholder",
                text: $settings.initialPrompt,
                axis: .vertical
            )
            .lineLimit(2...5)
        }
    }

    private var modelsOnDeviceSection: some View {
        Section {
            NavigationLink {
                ModelManagerView()
                    .environment(model)
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
    }

    private var workflowsSection: some View {
        Section {
            NavigationLink {
                AutoExportSettings()
                    .environment(model)
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
                    .environment(model)
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
                    .environment(model)
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
    }

    private var welcomeSection: some View {
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
    }

    private var aboutSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parola")
                        .font(.headline)
                    Text("On-device speech to text")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            LabeledContent("Version", value: appVersion)
            LabeledContent("Engine", value: activeModelLabel)
            LabeledContent("Models on device", value: modelsSummary)
        } header: {
            Text("About")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    private var activeModelLabel: String {
        model.availableModels.first { $0.name == model.settings.modelName }?.label
            ?? model.settings.modelName
    }

    private var modelsSummary: String {
        let installed = model.availableModels.filter(\.isInstalled)
        let bytes = installed.reduce(0) { $0 + ($1.approximateSizeBytes ?? 0) }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(installed.count) · \(size)"
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

    private var visibleSections: Set<SettingsSection> {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Set(SettingsSection.allCases) }
        return Set(SettingsSection.allCases.filter { $0.matches(trimmed) })
    }
}

private enum SettingsSection: CaseIterable {
    case activeModel
    case appearance
    case vocabulary
    case modelsOnDevice
    case workflows
    case welcome
    case about

    var keywords: [String] {
        switch self {
        case .activeModel:
            return ["active model", "model", "language", "translate", "word timestamps"]
        case .appearance:
            return ["appearance", "theme", "dark", "light", "color", "automatic"]
        case .vocabulary:
            return ["vocabulary", "prompt"]
        case .modelsOnDevice:
            return ["models on device", "model", "download", "storage"]
        case .workflows:
            return ["auto-export", "export", "ignored segments", "filters", "find", "replace"]
        case .welcome:
            return ["welcome", "onboarding", "tutorial"]
        case .about:
            return ["about", "version", "credits"]
        }
    }

    func matches(_ query: String) -> Bool {
        keywords.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
