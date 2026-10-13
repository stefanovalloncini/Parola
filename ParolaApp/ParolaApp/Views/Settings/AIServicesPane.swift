import SwiftUI
import ParolaCore

/// A service being edited, with the key the user typed but hasn't saved.
struct AIServiceDraft: Identifiable {
    var service: AIServiceConfig
    var isNew: Bool
    var apiKey: String = ""

    var id: UUID { service.id }
}

/// An action held back until the "transcripts leave this Mac" notice is accepted.
struct PendingRemoteAIAction: Identifiable {
    enum Kind {
        case save(AIServiceConfig, apiKey: String)
        case select(LanguageModelProviderChoice, LanguageModelTask)
    }

    let id = UUID()
    let kind: Kind
    let serviceName: String
}

struct AIServicesPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AIServiceDraft?
    @State private var pendingRemote: PendingRemoteAIAction?
    @State private var onDevice: LanguageModelFactory.OnDeviceAvailability?
    @State private var results: [UUID: AIServiceTestResult] = [:]
    @State private var testing: Set<UUID> = []

    var body: some View {
        SettingsForm {
            privacySection
            onDeviceSection
            servicesSection
            useForSection
            SettingHelper(text: "Apple Intelligence answers on this Mac. Anything else sends the text of the transcript to that service.")
            ResetPaneButton(scope: .aiServices)
        }
        .task { onDevice = await LanguageModelFactory.onDeviceAvailability() }
        .sheet(item: $editing) { draft in
            AIServiceEditor(
                draft: draft,
                onSave: { saved, key in save(saved, apiKey: key) },
                onCancel: { editing = nil }
            )
            .environment(model)
        }
        .sheet(item: $pendingRemote) { action in
            RemoteAIAcknowledgementSheet(
                serviceName: action.serviceName,
                onAccept: { accept(action) },
                onCancel: { pendingRemote = nil }
            )
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        @Bindable var model = model
        let policy = model.managedConfiguration.policyDisablesCloudLLM
        return SettingsSection {
            SettingRow("Keep AI on this Mac",
                       description: policy ? "Your organization keeps AI on this Mac." : "Never send transcripts to an online service.") {
                Toggle("", isOn: policy ? .constant(true) : $model.userPrivacyMode)
                    .labelsHidden()
                    .disabled(policy)
                    .axLeaf("Privacy.Toggle.PrivacyMode")
            }
        }
    }

    // MARK: - On device

    private var onDeviceSection: some View {
        SettingsSection {
            SettingRow("Apple Intelligence", descriptionVerbatim: onDeviceStatus) {
                Image(systemName: onDevice?.isAvailable == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(onDevice?.isAvailable == true ? DS.Palette.success : DS.Color.secondaryText)
                    .axLeaf("AIServices.Row.onDevice")
            }
        }
    }

    private var onDeviceStatus: String {
        guard let onDevice else { return String(localized: "Checking…") }
        return onDevice.reason.map { FailureText.reason($0) } ?? String(localized: "Ready")
    }

    // MARK: - Configured services

    private var servicesSection: some View {
        Section {
            servicesList
        } header: {
            Text("Your services")
        } footer: {
            HStack {
                Spacer()
                addMenu
            }
        }
    }

    private var servicesList: some View {
        Group {
            let services = model.listedAIServices
            if services.isEmpty {
                InlineEmptyText("No services yet")
            } else {
                ForEach(Array(services.enumerated()), id: \.element.id) { position, service in
                    AIServiceRow(
                        service: service,
                        isPaused: model.aiServicePaused(service),
                        result: results[service.id],
                        isTesting: testing.contains(service.id),
                        onEdit: { editing = AIServiceDraft(service: service, isNew: false) },
                        onTest: { test(service) },
                        onRemove: {
                            results[service.id] = nil
                            model.removeAIService(id: service.id)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Add

    private var addMenu: some View {
        Menu("Add Service") { addMenuItems }
            .fixedSize()
            // Hosted in this pane, the Menu's own AXMenuButton comes out unnamed; the stand-in carries the title.
            .accessibilityRepresentation { Menu("Add Service") { addMenuItems } }
            .axLeaf("AIServices.Menu.Add")
    }

    private var addMenuItems: some View {
        ForEach(model.addableAIServiceKinds, id: \.self) { kind in
            Button { add(kind) } label: {
                Label(kind.displayName, systemImage: configured(kind) == nil ? kind.symbol : "checkmark")
                    .labelStyle(.titleAndIcon)
            }
            .axLeaf("AIServices.Add.\(kind.rawValue)")
        }
    }

    private func configured(_ kind: AIServiceConfig.Kind) -> AIServiceConfig? {
        model.listedAIServices.first { $0.kind == kind }
    }

    /// One service per kind: a tile whose kind is already configured opens that row instead of
    /// adding a second one.
    private func add(_ kind: AIServiceConfig.Kind) {
        if let existing = configured(kind) {
            editing = AIServiceDraft(service: existing, isNew: false)
            return
        }
        editing = AIServiceDraft(
            service: AIServiceConfig(
                kind: kind,
                name: kind.displayName,
                endpoint: kind == .ollama ? AIServiceConfig.defaultOllamaEndpoint : nil,
                model: kind.defaultModel
            ),
            isNew: true
        )
    }

    // MARK: - Use for

    private var useForSection: some View {
        SettingsSection("Use for") {
            ForEach(Array(LanguageModelTask.allCases.enumerated()), id: \.element) { position, task in
                SettingRow(AIServicesPane.taskTitle(task)) {
                    Picker("", selection: binding(for: task)) {
                        Text("Apple Intelligence").tag(LanguageModelProviderChoice.onDevice)
                        ForEach(model.visibleAIServices) { service in
                            Text(verbatim: service.name).tag(service.choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200, alignment: .trailing)
                    .axLeaf("AIServices.Picker.\(task.rawValue)")
                }
            }
        }
    }

    static func taskTitle(_ task: LanguageModelTask) -> LocalizedStringKey {
        switch task {
        case .summary: return "Summary"
        case .chat: return "Chat"
        case .prompts: return "Transcript menu prompts"
        case .dictationCleanup: return "Dictation cleanup"
        }
    }

    private func binding(for task: LanguageModelTask) -> Binding<LanguageModelProviderChoice> {
        Binding(
            get: { model.resolvedLanguageModelChoice(for: task) },
            set: { choice in
                guard model.needsRemoteAIAcknowledgement(for: choice) else {
                    model.setLanguageModel(choice, for: task)
                    return
                }
                pendingRemote = PendingRemoteAIAction(
                    kind: .select(choice, task),
                    serviceName: model.aiService(for: choice)?.name ?? ""
                )
            }
        )
    }

    // MARK: - Actions

    private func save(_ service: AIServiceConfig, apiKey: String) {
        editing = nil
        guard model.needsRemoteAIAcknowledgement(for: service.choice) else {
            Task { await model.saveAIService(service, apiKey: apiKey) }
            return
        }
        pendingRemote = PendingRemoteAIAction(
            kind: .save(service, apiKey: apiKey),
            serviceName: service.name
        )
    }

    private func accept(_ action: PendingRemoteAIAction) {
        model.acknowledgeRemoteAI()
        pendingRemote = nil
        switch action.kind {
        case .save(let service, let apiKey):
            Task { await model.saveAIService(service, apiKey: apiKey) }
        case .select(let choice, let task):
            model.setLanguageModel(choice, for: task)
        }
    }

    private func test(_ service: AIServiceConfig) {
        testing.insert(service.id)
        Task {
            let result = await model.testAIService(service, apiKey: nil)
            results[service.id] = result
            testing.remove(service.id)
        }
    }
}

// MARK: - Row

private struct AIServiceRow: View {
    let service: AIServiceConfig
    let isPaused: Bool
    let result: AIServiceTestResult?
    let isTesting: Bool
    let onEdit: () -> Void
    let onTest: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                header
                if isPaused {
                    Text("Not used while AI stays on this Mac.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .axLeaf(leaf("Label.Paused"))
                }
                if let result {
                    AIServiceTestLabel(result: result)
                        .axLeaf(leaf("Label.TestResult"))
                }
            }
        }
    }

    private func leaf(_ suffix: String) -> String {
        "AIServices.Row.\(service.kind.rawValue).\(suffix)"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: service.kind.symbol)
                .foregroundStyle(DS.Color.accent)
                .frame(width: 20)
                .opacity(isPaused ? 0.5 : 1)
                // On the icon, not the row: an identifier on a container propagates to every
                // control inside it, and each button here carries its own.
                .axLeaf("AIServices.Row.\(service.kind.rawValue)")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: service.name)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.primaryText)
                Text(verbatim: subtitle)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(isPaused ? 0.5 : 1)
            Spacer(minLength: 8)
            if isTesting { ProgressView().controlSize(.small) }
            Button("Test", action: onTest)
                .disabled(isTesting || isPaused)
                .axLeaf(leaf("Button.Test"))
            Button("Edit…", action: onEdit)
                .axLeaf(leaf("Button.Edit"))
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .axLeaf(leaf("Button.Remove"))
        }
    }

    private var subtitle: String {
        var parts = [service.model.isEmpty ? String(localized: "No model") : service.model]
        if service.kind.usesEndpoint, let endpoint = service.endpoint {
            parts.append(endpoint.absoluteString)
        }
        if service.kind.keyProviderID != nil {
            parts.append(service.hasKey ? String(localized: "Key saved") : String(localized: "No key"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Shared by the row and the editor so a Test reads the same in both places.
struct AIServiceTestLabel: View {
    let result: AIServiceTestResult

    var body: some View {
        Label {
            Text(verbatim: text)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.ok ? DS.Palette.success : DS.Palette.warning)
        }
    }

    private var text: String {
        guard result.ok else { return result.message }
        return "\(result.message) · \(result.milliseconds) ms"
    }
}
