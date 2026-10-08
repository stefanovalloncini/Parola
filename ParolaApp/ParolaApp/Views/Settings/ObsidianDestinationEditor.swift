import AppKit
import SwiftUI
import ParolaCore

struct ObsidianDestinationEditor: View {
    @Environment(AppModel.self) private var model
    @State private var draft: ObsidianVaultFolderDestination
    @State private var testNote: TestNoteOutcome?
    @State private var isSendingTestNote = false
    let isNew: Bool
    let onSave: (ObsidianVaultFolderDestination) -> Void
    let onCancel: () -> Void

    init(
        destination: ObsidianVaultFolderDestination,
        isNew: Bool,
        onSave: @escaping (ObsidianVaultFolderDestination) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: destination)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        SheetFrame(
            title: isNew ? "New Destination" : "Edit Destination",
            onClose: onCancel
        ) {
            Form {
                folderSection
                namingSection
                frontmatterSection
                bodySection
                testSection
            }
            .formStyle(.grouped)
        } footer: {
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .sheetSecondaryAction()
                    .keyboardShortcut(.cancelAction)
                    .axLeaf("SendTo.Button.CancelEdit")
                Button("Save") { onSave(draft) }
                    .sheetPrimaryAction()
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.vaultBookmark.isEmpty)
                    .axLeaf("SendTo.Button.Save")
            }
        }
        .sheetSize(width: 560, minHeight: 520, maxHeight: 720)
        .footerHasCancel()
    }

    // MARK: - Sections

    private var folderSection: some View {
        SettingsSection("Vault") {
            SettingRow("Name", description: "What this destination is called in the Send to menu.", isFirst: true) {
                TextField("", text: $draft.name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .axLeaf("SendTo.TextField.Name")
            }
            SettingRow("Folder", descriptionVerbatim: draft.vaultPath.isEmpty ? String(localized: "No folder picked") : draft.vaultPath) {
                Button("Choose…", action: pickFolder)
                    .sheetButton()
                    .axLeaf("SendTo.Button.ChooseFolder")
            }
            SettingRow("Subfolder", description: "Relative to the vault. Leave empty to write into the vault root.") {
                TextField("", text: $draft.subfolder, prompt: Text("Transcripts"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .axLeaf("SendTo.TextField.Subfolder")
            }
        }
    }

    private var namingSection: some View {
        SettingsSection("Note name") {
            SettingRow("Filename", descriptionVerbatim: filenameHelp, isFirst: true) {
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

    private var frontmatterSection: some View {
        SettingsSection("Frontmatter") {
            toggleRow("Title", isOn: $draft.frontmatter.title, leaf: "Title", isFirst: true)
            toggleRow("Date", isOn: $draft.frontmatter.date, leaf: "Date")
            toggleRow("Duration", isOn: $draft.frontmatter.duration, leaf: "Duration")
            toggleRow("Source", isOn: $draft.frontmatter.source, leaf: "Source")
            toggleRow("Language", isOn: $draft.frontmatter.language, leaf: "Language")
            toggleRow("Model", isOn: $draft.frontmatter.model, leaf: "Model")
            toggleRow("Speakers", isOn: $draft.frontmatter.speakers, leaf: "FrontmatterSpeakers")
            toggleRow("Tags", isOn: $draft.frontmatter.tags, leaf: "Tags")
            toggleRow("Summary", isOn: $draft.frontmatter.summary, leaf: "FrontmatterSummary")
        }
    }

    private var bodySection: some View {
        SettingsSection("Note body") {
            toggleRow("Summary", isOn: $draft.body.summary, leaf: "BodySummary", isFirst: true)
            toggleRow("Transcript", isOn: $draft.body.transcript, leaf: "BodyTranscript")
            toggleRow("Timestamps", isOn: $draft.body.timestamps, leaf: "BodyTimestamps")
            toggleRow("Speaker names", isOn: $draft.body.speakers, leaf: "BodySpeakers")
            toggleRow("Favorites", isOn: $draft.body.favorites, leaf: "BodyFavorites")
            SettingRow("Link speaker names", description: "Writes a speaker as [[Name]] so Obsidian links the note to a person.") {
                Toggle("", isOn: $draft.wikilinks)
                    .labelsHidden()
                    .axLeaf("SendTo.Toggle.Wikilinks")
            }
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Send a Test Note", action: sendTestNote)
                    .sheetButton()
                    .disabled(draft.vaultBookmark.isEmpty || isSendingTestNote)
                    .axLeaf("SendTo.Button.TestNote")
                if isSendingTestNote {
                    ProgressView().controlSize(.small)
                }
            }
            switch testNote {
            case .written(let url):
                Label {
                    Text("Wrote \(url?.path ?? "")")
                        .font(DS.Font.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.success)
                }
                .axLeaf("SendTo.Label.TestNoteResult")
            case .failed(let message):
                Label {
                    Text(verbatim: message)
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.warning)
                }
                .axLeaf("SendTo.Label.TestNoteResult")
            case nil:
                EmptyView()
            }
        }
    }

    private func toggleRow(
        _ title: LocalizedStringKey,
        isOn: Binding<Bool>,
        leaf: String,
        isFirst: Bool = false
    ) -> some View {
        SettingRow(title, isFirst: isFirst) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .axLeaf("SendTo.Toggle.\(leaf)")
        }
    }

    // MARK: - Actions

    /// Built once: the example is recomputed on every keystroke in the template field, and the
    /// payload carries a rendered Markdown export.
    private static let samplePayload = AppModel.sampleDeliveryPayload()

    private var filenameHelp: String {
        let example = ObsidianNoteRenderer.filename(
            template: draft.filenameTemplate,
            payload: Self.samplePayload
        )
        let tokens = ObsidianNoteRenderer.filenameTokens.joined(separator: " ")
        return String(localized: "\(tokens) — for example \(example).md")
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the Obsidian vault folder Parola writes notes into.")
        guard panel.runModal() == .OK, let url = panel.url, url.hasDirectoryPath else { return }
        do {
            draft.vaultBookmark = try ObsidianVaultFolderDestination.bookmark(for: url)
            draft.vaultPath = url.path
            testNote = nil
        } catch {
            testNote = .failed(error.localizedDescription)
        }
    }

    private func sendTestNote() {
        isSendingTestNote = true
        let destination = draft
        Task {
            testNote = await model.sendTestNote(to: destination)
            isSendingTestNote = false
        }
    }
}
