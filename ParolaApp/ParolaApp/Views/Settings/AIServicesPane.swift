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
        VStack(alignment: .leading, spacing: 16) {
            privacySection
            onDeviceSection
            servicesSection
            addSection
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
                       description: policy ? "Your organization keeps AI on this Mac." : "Never send transcripts to an online service.",
                       isFirst: true) {
                Toggle("", isOn: policy ? .constant(true) : $model.userPrivacyMode)
                    .labelsHidden()
                    .disabled(policy)
                    .axLeaf("Privacy.Toggle.PrivacyMode")
            }
        }
    }

    // MARK: - On device

    private var onDeviceSection: some View {
        SettingsSection("On device") {
            SettingRow("Apple Intelligence", descriptionVerbatim: onDeviceStatus, isFirst: true) {
                Image(systemName: onDevice?.isAvailable == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(onDevice?.isAvailable == true ? DS.Palette.success : DS.Color.secondaryText)
                    .axLeaf("AIServices.Row.onDevice")
            }
        }
    }

    private var onDeviceStatus: String {
        guard let onDevice else { return String(localized: "Checking…") }
        return onDevice.reason ?? String(localized: "Ready")
    }

    // MARK: - Configured services

    private var servicesSection: some View {
        SettingsSection("Your services") {
            let services = model.listedAIServices
            if services.isEmpty {
                InlineEmptyText("No services yet")
            } else {
                ForEach(Array(services.enumerated()), id: \.element.id) { position, service in
                    AIServiceRow(
                        service: service,
                        isFirst: position == 0,
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

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("ADD A SERVICE")
            LeadingFlow(spacing: 8) {
                ForEach(model.addableAIServiceKinds, id: \.self) { kind in
                    AIServiceTile(kind: kind, isConfigured: configured(kind) != nil) { add(kind) }
                }
            }
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
                SettingRow(AIServicesPane.taskTitle(task), isFirst: position == 0) {
                    Picker("", selection: binding(for: task)) {
                        Text("On device").tag(LanguageModelProviderChoice.onDevice)
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
        case .prompts: return "Prompts"
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
    let isFirst: Bool
    let isPaused: Bool
    let result: AIServiceTestResult?
    let isTesting: Bool
    let onEdit: () -> Void
    let onTest: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, DS.Spacing.medium) }
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
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.small)
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
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .disabled(isTesting || isPaused)
                .axLeaf(leaf("Button.Test"))
            Button("Edit…", action: onEdit)
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
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

// MARK: - Tile

private struct AIServiceTile: View {
    let kind: AIServiceConfig.Kind
    let isConfigured: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .foregroundStyle(DS.Color.accent)
                Text(verbatim: kind.displayName)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: isConfigured ? "checkmark" : "plus")
                    .font(.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .fill(DS.Color.surfaceElevated)
            )
        }
        .buttonStyle(.plain)
        .axLeaf("AIServices.Add.\(kind.rawValue)")
    }
}
