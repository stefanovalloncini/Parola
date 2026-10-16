import SwiftUI
import ParolaCore

struct NotionDestinationEditor: View {
    @Environment(AppModel.self) private var model
    @State private var draft: NotionDestination
    @State private var secretInput = ""
    @State private var pageLink: String
    @State private var isSecretSaved = false
    @State private var saveError: String?
    @State private var saving = false
    let isNew: Bool
    let onSave: (NotionDestination) -> Void
    let onCancel: () -> Void

    init(
        destination: NotionDestination,
        isNew: Bool,
        onSave: @escaping (NotionDestination) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: destination)
        _pageLink = State(initialValue: destination.parentPageID)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        SheetFrame(title: isNew ? "New Destination" : "Edit Destination", onClose: cancel) {
            Form {
                SettingsSection("Notion") {
                    SettingRow("Name", description: "What this destination is called in the Send to menu.") {
                        TextField("", text: $draft.name)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .axLeaf("SendTo.TextField.Name")
                    }
                    SecretFieldRow(
                        title: "Integration secret",
                        description: "Create an integration in Notion and copy its secret here. It is kept in the Keychain.",
                        reference: draft.secretRef, prompt: "ntn_…", leaf: "SendTo.SecureField.NotionSecret",
                        input: $secretInput
                    )
                    SettingRow("Parent page", description: "Paste the link of a Notion page. Each transcript becomes a page under it. Share that page with your integration.") {
                        TextField("", text: $pageLink, prompt: Text(verbatim: "https://www.notion.so/…"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .autocorrectionDisabled()
                            .axLeaf("SendTo.TextField.NotionPage")
                    }
                    if !pageLink.trimmingCharacters(in: .whitespaces).isEmpty, parsedPage == nil {
                        SettingsWarning(String(localized: "Parola can't find a page ID in that. Paste the page's link."))
                            .font(DS.Font.secondary)
                            .axLeaf("SendTo.Label.PageProblem")
                    }
                }
                SettingsSection {
                    EditorCheckSection(
                        buttons: [("Check Connection", "SendTo.Button.CheckConnection", check)],
                        canRun: parsedPage != nil
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
                    .disabled(parsedPage == nil || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || !(isSecretSaved || !secretInput.isEmpty) || saving)
                    .axLeaf("SendTo.Button.Save")
            }
        }
        .sheetSize(width: 560, minHeight: 420, maxHeight: 640)
        .footerHasCancel()
        .task(id: draft.secretRef) { isSecretSaved = await model.hasSavedSecret(draft.secretRef) }
    }

    private var parsedPage: String? { NotionPageID.parse(pageLink) }

    private var unsavedSecrets: [String: String] {
        secretInput.isEmpty ? [:] : [draft.secretRef: secretInput]
    }

    private func check() async -> EditorCheckResult {
        var candidate = draft
        candidate.parentPageID = parsedPage ?? ""
        return await model.checkNotionConnection(candidate, unsavedSecrets: unsavedSecrets)
    }

    private func cancel() {
        guard !saving else { return }
        onCancel()
    }

    private func save() {
        guard !saving else { return }
        saving = true
        var cleaned = draft
        cleaned.parentPageID = parsedPage ?? ""
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
