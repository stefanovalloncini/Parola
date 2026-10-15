import SwiftUI
import ParolaCore

struct ObsidianRESTDestinationEditor: View {
    @Environment(AppModel.self) private var model
    @State private var draft: ObsidianLocalRESTDestination
    @State private var keyInput = ""
    @State private var isKeySaved = false
    @State private var saveError: String?
    let isNew: Bool
    let onSave: (ObsidianLocalRESTDestination) -> Void
    let onCancel: () -> Void

    init(
        destination: ObsidianLocalRESTDestination,
        isNew: Bool,
        onSave: @escaping (ObsidianLocalRESTDestination) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: destination)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        SheetFrame(title: isNew ? "New Destination" : "Edit Destination", onClose: onCancel) {
            Form {
                connectionSection
                namingSection
                ObsidianNoteOptionsSections(
                    frontmatter: $draft.frontmatter, noteBody: $draft.body, wikilinks: $draft.wikilinks
                )
                SettingsSection {
                    EditorCheckSection(
                        buttons: [
                            ("Check Connection", "SendTo.Button.CheckConnection", check),
                            ("Send a Test Note", "SendTo.Button.TestNote", sendTestNote),
                        ],
                        canRun: addressIsValid
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
                Button("Cancel", action: onCancel)
                    .sheetSecondaryAction()
                    .keyboardShortcut(.cancelAction)
                    .axLeaf("SendTo.Button.CancelEdit")
                Button("Save", action: save)
                    .sheetPrimaryAction()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!addressIsValid || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || !(isKeySaved || !keyInput.isEmpty))
                    .axLeaf("SendTo.Button.Save")
            }
        }
        .sheetSize(width: 560, minHeight: 520, maxHeight: 720)
        .footerHasCancel()
        .task(id: draft.secretRef) { isKeySaved = await model.hasSavedSecret(draft.secretRef) }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        SettingsSection("Obsidian Local REST") {
            SettingRow("Name", description: "What this destination is called in the Send to menu.") {
                TextField("", text: $draft.name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .axLeaf("SendTo.TextField.Name")
            }
            SettingRow("Address", description: "Where the Local REST API plugin listens. Obsidian has to be open. Its certificate is self-signed, and Parola trusts it only on this Mac.") {
                TextField("", text: $draft.baseURLText, prompt: Text(verbatim: ObsidianLocalRESTDestination.defaultBaseURL))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .autocorrectionDisabled()
                    .axLeaf("SendTo.TextField.RESTAddress")
            }
            if let message = addressProblem {
                SettingsWarning(message)
                    .font(DS.Font.secondary)
                    .axLeaf("SendTo.Label.AddressProblem")
            }
            SecretFieldRow(
                title: "API key",
                description: "Copy it from the plugin's settings in Obsidian. It is kept in the Keychain.",
                reference: draft.secretRef, prompt: String(localized: "Paste the key"), leaf: "SendTo.SecureField.RESTKey",
                input: $keyInput
            )
            SettingRow("Folder", description: "Inside the vault. Leave empty to write into the vault root.") {
                TextField("", text: $draft.folder, prompt: Text("Transcripts"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .axLeaf("SendTo.TextField.Subfolder")
            }
        }
    }

    private var namingSection: some View {
        SettingsSection("Note name") {
            SettingRow("Filename", descriptionVerbatim: filenameHelp) {
                TextField("", text: $draft.filenameTemplate, prompt: Text(verbatim: ObsidianVaultFolderDestination.defaultFilenameTemplate))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .axLeaf("SendTo.TextField.FilenameTemplate")
            }
            SettingRow("When the note exists", description: "Keep both writes a second note with a counter.") {
                Picker("", selection: $draft.collision) {
                    ForEach(ObsidianCollisionPolicy.allCases) { policy in
                        Text(LocalizedStringKey(policy.displayName)).tag(policy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160, alignment: .trailing)
                .axLeaf("SendTo.Picker.Collision")
            }
        }
    }

    // MARK: - State

    private static let samplePayload = AppModel.sampleDeliveryPayload()

    private var filenameHelp: String {
        let example = ObsidianNoteRenderer.filename(template: draft.filenameTemplate, payload: Self.samplePayload)
        let tokens = ObsidianNoteRenderer.filenameTokens.joined(separator: " ")
        return String(localized: "\(tokens) — for example \(example).md")
    }

    private var addressIsValid: Bool {
        if case .success = ObsidianLocalRESTDestination.validateBaseURL(draft.baseURLText) { return true }
        return false
    }

    private var addressProblem: String? {
        guard !addressIsValid, !draft.baseURLText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return String(localized: "Use an https:// address, or an http:// one on this Mac or your local network.")
    }

    private var unsavedSecrets: [String: String] {
        keyInput.isEmpty ? [:] : [draft.secretRef: keyInput]
    }

    private func check() async -> EditorCheckResult {
        await model.checkObsidianRESTConnection(draft, unsavedSecrets: unsavedSecrets)
    }

    private func sendTestNote() async -> EditorCheckResult {
        await model.sendObsidianRESTTestNote(draft, unsavedSecrets: unsavedSecrets)
    }

    private func save() {
        var cleaned = draft
        cleaned.baseURLText = cleaned.baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let secrets = unsavedSecrets
        Task {
            do {
                try await model.writeDestinationSecrets(secrets)
                onSave(cleaned)
            } catch {
                saveError = FailureText.message(for: error)
            }
        }
    }
}
