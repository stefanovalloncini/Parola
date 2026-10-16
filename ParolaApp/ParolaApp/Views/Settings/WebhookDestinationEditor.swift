import SwiftUI
import ParolaCore

struct WebhookDestinationEditor: View {
    @Environment(AppModel.self) private var model
    @State private var draft: WebhookDestination
    @State private var headerValues: [UUID: String] = [:]
    @State private var saveError: String?
    @State private var saving = false
    @State private var savedRefs: Set<String>?
    let isNew: Bool
    let onSave: (WebhookDestination) -> Void
    let onCancel: () -> Void

    init(
        destination: WebhookDestination,
        isNew: Bool,
        onSave: @escaping (WebhookDestination) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: destination)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        SheetFrame(title: isNew ? "New Destination" : "Edit Destination", onClose: cancel) {
            Form {
                addressSection
                headersSection
                contentSection
                SettingsSection {
                    EditorCheckSection(
                        buttons: [("Send Test", "SendTo.Button.SendTest", sendTest)],
                        canRun: urlIsValid
                    )
                }
            }
            .formStyle(.grouped)
        } footer: {
            HStack {
                if let saveError {
                    SettingsWarning(saveError).font(DS.Font.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .sheetSecondaryAction()
                    .disabled(saving)
                    .keyboardShortcut(.cancelAction)
                    .axLeaf("SendTo.Button.CancelEdit")
                Button("Save", action: save)
                    .sheetPrimaryAction()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!urlIsValid || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || headersProblem != nil || saving)
                    .axLeaf("SendTo.Button.Save")
            }
        }
        .sheetSize(width: 560, minHeight: 480, maxHeight: 720)
        .footerHasCancel()
        .task(id: draft.headers.map(\.secretRef)) { savedRefs = await model.savedSecretReferences(draft.headers.map(\.secretRef)) }
    }

    // MARK: - Sections

    private var addressSection: some View {
        SettingsSection("Webhook") {
            SettingRow("Name", description: "What this destination is called in the Send to menu.") {
                TextField("", text: $draft.name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .axLeaf("SendTo.TextField.Name")
            }
            SettingRow("Address", description: "Works with the catch hooks in Zapier, Make and n8n, or any server that takes a JSON POST.") {
                TextField("", text: $draft.urlText, prompt: Text(verbatim: "https://"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .autocorrectionDisabled()
                    .axLeaf("SendTo.TextField.WebhookURL")
            }
            if let message = addressProblem {
                SettingsWarning(message)
                    .font(DS.Font.secondary)
                    .axLeaf("SendTo.Label.AddressProblem")
            } else if isUnencrypted {
                Label("Not encrypted. Anyone on the network can read what Parola sends.", systemImage: "lock.open.fill")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .axLeaf("SendTo.Label.NotEncrypted")
            }
        }
    }

    private var headersSection: some View {
        SettingsSection("Headers") {
            ForEach($draft.headers) { $header in
                HStack(spacing: 8) {
                    TextField("", text: $header.name, prompt: Text("Name"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .axLeaf("SendTo.TextField.HeaderName.\(header.id.uuidString)")
                    HeaderValueField(header: header, input: valueBinding(header.id))
                    Button {
                        draft.headers.removeAll { $0.id == header.id }
                        headerValues[header.id] = nil
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove Header")
                    .accessibilityLabel("Remove Header")
                    .axLeaf("SendTo.Button.RemoveHeader.\(header.id.uuidString)")
                }
            }
            HStack {
                Button("Add Header") { draft.headers.append(WebhookHeader(name: "")) }
                    .sheetButton()
                    .axLeaf("SendTo.Button.AddHeader")
                Spacer()
            }
            if let headersProblem {
                SettingsWarning(headersProblem)
                    .font(DS.Font.secondary)
                    .axLeaf("SendTo.Label.HeadersProblem")
            }
            Text("Header values are kept in the Keychain.")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
        }
    }

    private var contentSection: some View {
        SettingsSection("Content") {
            SettingRow("Include segments", description: "Adds each segment with its start, end and speaker. Off sends the text only.") {
                Toggle("", isOn: $draft.includeSegments)
                    .labelsHidden()
                    .axLeaf("SendTo.Toggle.IncludeSegments")
            }
        }
    }

    // MARK: - State

    private var addressProblem: String? {
        guard !draft.urlText.trimmingCharacters(in: .whitespaces).isEmpty,
              case .failure(let error) = WebhookURLPolicy.validate(draft.urlText) else { return nil }
        switch error {
        case .empty: return nil
        case .notAURL: return String(localized: "That isn't a web address.")
        case .unsupportedScheme: return String(localized: "The address has to start with https:// or http://.")
        case .insecurePublicHost:
            return String(localized: "An address on the internet has to start with https://. Plain http:// is only for this Mac and your local network.")
        }
    }

    private var urlIsValid: Bool {
        if case .success = WebhookURLPolicy.validate(draft.urlText) { return true }
        return false
    }

    private var isUnencrypted: Bool {
        if case .success(let url) = WebhookURLPolicy.validate(draft.urlText) { return WebhookURLPolicy.isUnencrypted(url) }
        return false
    }

    private func valueBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { headerValues[id] ?? "" }, set: { headerValues[id] = $0 })
    }

    private var namedHeaders: [WebhookHeader] {
        draft.headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var headersProblem: String? {
        switch WebhookHeaderValidation.problem(headers: draft.headers, typed: headerValues, saved: savedRefs) {
        case .blankName: return String(localized: "Every header needs a name.")
        case .missingValue: return String(localized: "Add a value for each header.")
        case nil: return nil
        }
    }

    private var unsavedSecrets: [String: String] {
        var values: [String: String] = [:]
        for header in namedHeaders {
            if let value = headerValues[header.id], !value.isEmpty { values[header.secretRef] = value }
        }
        return values
    }

    // MARK: - Actions

    private func sendTest() async -> EditorCheckResult {
        await model.sendWebhookTest(draft, unsavedSecrets: unsavedSecrets)
    }

    private func cancel() {
        guard !saving else { return }
        onCancel()
    }

    private func save() {
        guard !saving else { return }
        saving = true
        var cleaned = draft
        cleaned.headers = namedHeaders
        cleaned.urlText = cleaned.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let secrets = unsavedSecrets
        Task {
            do {
                try await model.writeDestinationSecrets(secrets)
                onSave(cleaned)
            } catch {
                saveError = FailureText.message(for: error)
                saving = false
            }
        }
    }
}

private struct HeaderValueField: View {
    @Environment(AppModel.self) private var model
    let header: WebhookHeader
    @Binding var input: String
    @State private var isSaved = false

    var body: some View {
        SecureField("", text: $input, prompt: Text(isSaved ? LocalizedStringKey("Saved in Keychain") : LocalizedStringKey("Value")))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .axLeaf("SendTo.SecureField.HeaderValue.\(header.id.uuidString)")
            .task(id: header.secretRef) { isSaved = await model.hasSavedSecret(header.secretRef) }
    }
}

/// What stops a webhook's headers from being saved. `saved` is nil until the Keychain lookup has answered,
/// and a missing value is not reported before then.
enum WebhookHeaderValidation {
    enum Problem: Equatable {
        case blankName
        case missingValue
    }

    static func problem(headers: [WebhookHeader], typed: [UUID: String], saved: Set<String>?) -> Problem? {
        let named = headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if named.count != headers.count { return .blankName }
        guard let saved else { return nil }
        let missing = named.contains { (typed[$0.id] ?? "").isEmpty && !saved.contains($0.secretRef) }
        return missing ? .missingValue : nil
    }
}
