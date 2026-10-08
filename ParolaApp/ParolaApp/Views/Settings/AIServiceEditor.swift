import SwiftUI
import ParolaCore

struct AIServiceEditor: View {
    @Environment(AppModel.self) private var model
    @State private var service: AIServiceConfig
    @State private var apiKey: String = ""
    @State private var endpointText: String
    @State private var ollamaModels: [String] = []
    @State private var ollamaReachable = true
    @State private var result: AIServiceTestResult?
    @State private var isTesting = false
    private let isNew: Bool
    let onSave: (AIServiceConfig, String) -> Void
    let onCancel: () -> Void

    init(
        draft: AIServiceDraft,
        onSave: @escaping (AIServiceConfig, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _service = State(initialValue: draft.service)
        _apiKey = State(initialValue: draft.apiKey)
        _endpointText = State(initialValue: draft.service.endpoint?.absoluteString ?? "")
        self.isNew = draft.isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        SheetFrame(
            titleVerbatim: service.kind.displayName,
            onClose: onCancel
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailsSection
                    if service.kind.keyProviderID != nil { keySection }
                    testSection
                }
                .padding(DS.Spacing.regular)
            }
        } footer: {
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .sheetSecondaryAction()
                    .keyboardShortcut(.cancelAction)
                    .axLeaf("AIServices.Button.Cancel")
                Button("Save") { onSave(saved(), apiKey) }
                    .sheetPrimaryAction()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .axLeaf("AIServices.Button.Save")
            }
        }
        .sheetSize(width: 560, minHeight: 380, maxHeight: 620)
        .footerHasCancel()
        .task(id: endpointText) { await reloadOllamaModels() }
    }

    // MARK: - Sections

    private var detailsSection: some View {
        SettingsSection("Service") {
            SettingRow("Name", description: "What this service is called in the pickers.", isFirst: true) {
                TextField("", text: $service.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .axLeaf("AIServices.TextField.Name")
            }
            if service.kind.usesEndpoint {
                SettingRow("Endpoint", descriptionVerbatim: endpointHelp) {
                    TextField(AIServiceConfig.defaultOllamaEndpoint.absoluteString, text: $endpointText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .axLeaf("AIServices.TextField.Endpoint")
                }
            }
            SettingRow("Model", descriptionVerbatim: modelHelp) {
                modelField
            }
        }
    }

    @ViewBuilder
    private var modelField: some View {
        if service.kind == .ollama && !ollamaOptions.isEmpty {
            Picker("", selection: $service.model) {
                ForEach(ollamaOptions, id: \.self) { name in
                    Text(verbatim: ollamaModels.contains(name) ? name : notInstalled(name)).tag(name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 240, alignment: .trailing)
            .axLeaf("AIServices.Picker.OllamaModel")
        } else {
            TextField(service.kind.defaultModel, text: $service.model)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .axLeaf("AIServices.TextField.Model")
        }
    }

    private var keySection: some View {
        SettingsSection("API key") {
            SettingRow("Key", descriptionVerbatim: keyHelp, isFirst: true) {
                SecureField(service.kind.apiKeyPlaceholder, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .axLeaf("AIServices.SecureField.APIKey")
            }
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Test", action: runTest)
                    .sheetButton()
                    .disabled(!canSave || isTesting || isPaused)
                    .axLeaf("AIServices.Button.Test")
                if isTesting { ProgressView().controlSize(.small) }
            }
            if isPaused {
                Text("Not used while AI stays on this Mac.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .axLeaf("AIServices.Label.Paused")
            }
            if let result {
                AIServiceTestLabel(result: result)
                    .axLeaf("AIServices.Label.TestResult")
            }
        }
    }

    // MARK: - Helpers

    private var endpointHelp: String {
        service.kind == .ollama
            ? String(localized: "Where Ollama listens. Models are read from it.")
            : String(localized: "The base URL of an OpenAI-compatible server, without /chat/completions.")
    }

    private var modelHelp: String {
        if service.kind == .ollama && !ollamaReachable {
            return String(localized: "Ollama isn't answering at that address — type the model name instead.")
        }
        return String(localized: "The model this service answers with.")
    }

    private var keyHelp: String {
        guard service.hasKey else { return String(localized: "Stored in your keychain, never in the settings file.") }
        return String(localized: "Key saved. Type a new one to replace it.")
    }

    private var isPaused: Bool {
        model.aiServicePaused(saved())
    }

    private var canSave: Bool {
        guard !service.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !service.model.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        guard service.kind.usesEndpoint else { return true }
        return parsedEndpoint != nil
    }

    private var parsedEndpoint: URL? {
        let trimmed = endpointText.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host() != nil else { return nil }
        return url
    }

    private func saved() -> AIServiceConfig {
        var out = service
        out.name = out.name.trimmingCharacters(in: .whitespaces)
        out.model = out.model.trimmingCharacters(in: .whitespaces)
        out.endpoint = service.kind.usesEndpoint ? parsedEndpoint : nil
        return out
    }

    /// The tag list plus the saved model when the server doesn't have it, so an edit never rewrites
    /// a model that was working.
    private var ollamaOptions: [String] {
        let saved = service.model.trimmingCharacters(in: .whitespaces)
        guard !saved.isEmpty, !ollamaModels.contains(saved) else { return ollamaModels }
        return [saved] + ollamaModels
    }

    private func notInstalled(_ name: String) -> String {
        String(localized: "\(name) (not installed)")
    }

    private func reloadOllamaModels() async {
        guard service.kind == .ollama, let endpoint = parsedEndpoint else {
            ollamaModels = []
            return
        }
        // Typed into per keystroke: the task is cancelled on the next one, so only a pause fetches.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let names = try await OllamaCatalog.installedModels(endpoint: endpoint)
            ollamaModels = names
            ollamaReachable = true
            if service.model.trimmingCharacters(in: .whitespaces).isEmpty, let first = names.first {
                service.model = first
            }
        } catch {
            ollamaModels = []
            ollamaReachable = false
        }
    }

    private func runTest() {
        isTesting = true
        let candidate = saved()
        let key = apiKey
        Task {
            result = await model.testAIService(candidate, apiKey: key)
            isTesting = false
        }
    }
}
