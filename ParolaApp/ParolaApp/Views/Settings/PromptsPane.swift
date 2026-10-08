import SwiftUI
import ParolaCore

struct PromptsPane: View {
    @Environment(AppModel.self) private var model
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .original
    @State private var userPrompts: [Prompt] = []
    @State private var editing: PromptEditDraft?
    @State private var pendingDelete: Prompt?
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SearchPill(text: $searchText, placeholder: "Search prompts…", leaf: "Prompts.TextField.Search")
                sortMenu
            }
            if saveFailed { saveErrorBanner }

            SettingsSection("Custom prompts") {
                let custom = visible(userPrompts)
                if custom.isEmpty {
                    InlineEmptyText(isSearching ? "No prompts match." : "No custom prompts yet")
                } else {
                    ForEach(Array(custom.enumerated()), id: \.element.id) { idx, prompt in
                        PromptRow(
                            prompt: prompt,
                            isFirst: idx == 0,
                            onEdit: { editing = PromptEditDraft(prompt: prompt) },
                            onDelete: { pendingDelete = prompt }
                        )
                    }
                }
            }

            HStack {
                Button {
                    editing = PromptEditDraft(prompt: Prompt(name: "", instructions: "", isBuiltIn: false))
                } label: {
                    Label("Add Prompt", systemImage: "plus.circle")
                }
                .axLeaf("Prompts.Button.AddPrompt")
                Spacer()
            }

            SettingsSection("Built-in prompts") {
                let builtIns = visible(Prompt.builtIns)
                if builtIns.isEmpty {
                    InlineEmptyText("No prompts match.")
                } else {
                    ForEach(Array(builtIns.enumerated()), id: \.element.id) { idx, prompt in
                        PromptRow(
                            prompt: prompt,
                            isFirst: idx == 0,
                            onEdit: { editing = PromptEditDraft(viewing: prompt) },
                            onDelete: {}
                        )
                    }
                }
            }

            SettingHelper(text: "Built-in prompts are read-only. Add your own to get a new entry in the Transcript menu.")
        }
        .task { await reload() }
        .sheet(item: $editing) { draft in
            PromptEditor(
                draft: draft,
                onCommit: { result in
                    Task {
                        await commit(result)
                        editing = nil
                    }
                },
                onDuplicate: { editing = $0.duplicate() },
                onCancel: { editing = nil }
            )
        }
        .confirmationDialog(
            String(localized: "Delete “\(pendingDelete?.name ?? "")”?"),
            isPresented: isConfirmingDelete,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { prompt in
            Button("Delete", role: .destructive) {
                delete(prompt)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func visible(_ prompts: [Prompt]) -> [Prompt] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var prompts = prompts
        if !query.isEmpty {
            prompts = prompts.filter { $0.name.lowercased().contains(query) }
        }
        switch sortOption {
        case .original:
            break
        case .nameAZ:
            prompts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameZA:
            prompts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
        return prompts
    }

    private var saveErrorBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't save your prompts")
                    .font(DS.Font.bodyStrong)
                Text("The change is only in this session. Check that Parola can write to its Application Support folder.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(DS.Spacing.small)
        .background(DS.Palette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        .axLeaf("Prompts.Text.SaveError")
    }

    private var sortMenu: some View {
        Menu {
            sortOptions
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(DSIconChipButtonStyle(side: 28))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort prompts")
        .accessibilityRepresentation {
            Menu("Sort prompts") { sortOptions }
        }
        .axLeaf("Prompts.Menu.Sort")
    }

    @ViewBuilder private var sortOptions: some View {
        ForEach(SortOption.allCases, id: \.self) { option in
            Button {
                sortOption = option
            } label: {
                if sortOption == option {
                    Label(option.label, systemImage: "checkmark")
                } else {
                    Text(option.label)
                }
            }
        }
    }

    @MainActor
    private func reload() async {
        userPrompts = await model.promptLibrary.userPrompts
    }

    @MainActor
    private func commit(_ draft: PromptEditDraft) async {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if draft.isExisting {
            let updated = Prompt(
                id: draft.id,
                name: trimmed,
                instructions: draft.instructions,
                isBuiltIn: false,
                triggerWords: draft.parsedTriggerWords,
                useSystemInstructions: !draft.assistantMode
            )
            saveFailed = await model.promptLibrary.updateUserPrompt(updated) == false
        } else {
            saveFailed = await model.promptLibrary.addUserPrompt(
                name: trimmed,
                instructions: draft.instructions,
                triggerWords: draft.parsedTriggerWords,
                useSystemInstructions: !draft.assistantMode
            ).saved == false
        }
        await reload()
        await model.refreshDictationTriggerPrompts()
    }

    @MainActor
    private func delete(_ prompt: Prompt) {
        guard !prompt.isBuiltIn else { return }
        let id = prompt.id
        Task {
            saveFailed = await model.promptLibrary.removeUserPrompt(id) == false
            await reload()
            await model.refreshDictationTriggerPrompts()
        }
    }

    enum SortOption: CaseIterable {
        case original, nameAZ, nameZA

        var label: LocalizedStringKey {
            switch self {
            case .original: return "Original order"
            case .nameAZ: return "Name A→Z"
            case .nameZA: return "Name Z→A"
            }
        }
    }
}

private struct PromptRow: View {
    let prompt: Prompt
    let isFirst: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SettingRow(titleVerbatim: prompt.name, isFirst: isFirst) {
            HStack(spacing: 6) {
                if prompt.isBuiltIn {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.borderless)
                    .help("Show prompt")
                    .accessibilityLabel("Show prompt")
                    .axLeaf("Prompts.Button.View")
                } else {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit prompt")
                    .accessibilityLabel("Edit prompt")
                    .axLeaf("Prompts.Button.Edit")
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete prompt")
                    .accessibilityLabel("Delete prompt")
                    .axLeaf("Prompts.Button.Delete")
                }
            }
        }
    }
}

@Observable
final class PromptEditDraft: Identifiable {
    let id: UUID
    let isExisting: Bool
    /// A built-in shown for reading; its one way forward is a copy.
    let isReadOnly: Bool
    var name: String
    var instructions: String
    var triggerWordsText: String
    var assistantMode: Bool

    convenience init(prompt: Prompt) {
        self.init(prompt: prompt, isExisting: !prompt.name.isEmpty, isReadOnly: false)
    }

    convenience init(viewing builtIn: Prompt) {
        self.init(prompt: builtIn, isExisting: true, isReadOnly: true)
    }

    private init(prompt: Prompt, isExisting: Bool, isReadOnly: Bool) {
        self.id = prompt.id
        self.isExisting = isExisting
        self.isReadOnly = isReadOnly
        self.name = prompt.name
        self.instructions = prompt.instructions
        self.triggerWordsText = prompt.triggerWords.joined(separator: ", ")
        self.assistantMode = !prompt.useSystemInstructions
    }

    /// Trigger words stay behind: two prompts can't answer to the same word.
    func duplicate() -> PromptEditDraft {
        PromptEditDraft(
            prompt: Prompt(
                name: String(localized: "\(name) copy"),
                instructions: instructions,
                useSystemInstructions: !assistantMode
            ),
            isExisting: false,
            isReadOnly: false
        )
    }

    var parsedTriggerWords: [String] {
        triggerWordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct PromptEditor: View {
    @Bindable var draft: PromptEditDraft
    let onCommit: (PromptEditDraft) -> Void
    let onDuplicate: (PromptEditDraft) -> Void
    let onCancel: () -> Void

    var body: some View {
        SheetFrame(title: title, onClose: onCancel) {
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                fields
            }
            .disabled(draft.isReadOnly)
            .padding(DS.Spacing.regular)
        } footer: {
            footer
        }
        .sheetDescription(Text(description))
        .footerHasCancel()
    }

    private var title: LocalizedStringKey {
        if draft.isReadOnly { return "Built-in Prompt" }
        return draft.isExisting ? "Edit Prompt" : "New Prompt"
    }

    private var description: LocalizedStringKey {
        draft.isReadOnly
            ? "Built-in prompts are read-only. Duplicate this one to change it."
            : "Parola sends these instructions to the model along with the text."
    }

    private var footer: some View {
        HStack {
            Spacer()
            if draft.isReadOnly {
                Button("Close", action: onCancel)
                    .sheetSecondaryAction()
                    .keyboardShortcut(.cancelAction)
                    .axLeaf("PromptEditor.Button.Close")
                Button("Duplicate") { onDuplicate(draft) }
                    .sheetPrimaryAction()
                    .keyboardShortcut(.defaultAction)
                    .axLeaf("PromptEditor.Button.Duplicate")
            } else {
                Button("Cancel", action: onCancel)
                    .sheetSecondaryAction()
                    .keyboardShortcut(.cancelAction)
                    .axLeaf("PromptEditor.Button.Cancel")
                Button("Save") { onCommit(draft) }
                    .sheetPrimaryAction()
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .axLeaf("PromptEditor.Button.Save")
            }
        }
    }

    @ViewBuilder private var fields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name").font(DS.Font.secondary).foregroundStyle(DS.Color.secondaryText)
            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .axLeaf("PromptEditor.TextField.Name")
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Instructions").font(DS.Font.secondary).foregroundStyle(DS.Color.secondaryText)
            TextEditor(text: $draft.instructions)
                .font(DS.Font.body)
                .frame(minHeight: 160)
                .padding(DS.Spacing.tight)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Trigger words").font(DS.Font.secondary).foregroundStyle(DS.Color.secondaryText)
            TextField("summary, recap", text: $draft.triggerWordsText)
                .textFieldStyle(.roundedBorder)
                .axLeaf("PromptEditor.TextField.TriggerWords")
            Text("Words that switch to this prompt for one dictation. Separate with commas.")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
        }

        VStack(alignment: .leading, spacing: 4) {
            Toggle("Assistant mode", isOn: $draft.assistantMode)
                .axLeaf("PromptEditor.Toggle.AssistantMode")
            Text("When on, the LLM answers your dictation instead of cleaning it up. Use this for voice Q&A.")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
        }
    }
}
