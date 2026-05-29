import SwiftUI
import ParolaCore

struct PromptsPane: View {
    @Environment(AppModel.self) private var model
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .builtInFirst
    @State private var userPrompts: [Prompt] = []
    @State private var editing: PromptEditDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchPill(text: $searchText, placeholder: "Search prompts…")
            sortRow

            SettingsSection {
                let visible = visiblePrompts
                if visible.isEmpty {
                    HStack {
                        Text("No prompts match.").foregroundStyle(.secondary).font(.body)
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, prompt in
                        PromptRow(
                            prompt: prompt,
                            isFirst: idx == 0,
                            onEdit: { editing = PromptEditDraft(prompt: prompt) },
                            onDelete: { delete(prompt) }
                        )
                    }
                }
            }

            HStack {
                Button {
                    editing = PromptEditDraft(prompt: Prompt(name: "", instructions: "", isBuiltIn: false))
                } label: {
                    Label("Add prompt", systemImage: "plus.circle")
                }
                .axLeaf("Prompts.Button.AddPrompt")
                Spacer()
            }

            SettingHelper(text: "Prompts rewrite transcripts after recording — used by dictation cleanup and the Transcript menu.")
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
                onCancel: { editing = nil }
            )
        }
    }

    private var allPrompts: [Prompt] {
        Prompt.builtIns + userPrompts
    }

    private var visiblePrompts: [Prompt] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var prompts = allPrompts
        if !query.isEmpty {
            prompts = prompts.filter { $0.name.lowercased().contains(query) }
        }
        switch sortOption {
        case .builtInFirst:
            prompts.sort { lhs, rhs in
                if lhs.isBuiltIn == rhs.isBuiltIn { return false }
                return lhs.isBuiltIn
            }
        case .nameAZ:
            prompts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameZA:
            prompts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
        return prompts
    }

    private var sortRow: some View {
        HStack {
            Spacer()
            Menu {
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
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort prompts")
            .axLeaf("Prompts.Menu.Sort")
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
            await model.promptLibrary.updateUserPrompt(updated)
        } else {
            _ = await model.promptLibrary.addUserPrompt(
                name: trimmed,
                instructions: draft.instructions,
                triggerWords: draft.parsedTriggerWords,
                useSystemInstructions: !draft.assistantMode
            )
        }
        await reload()
        await model.refreshDictationTriggerPrompts()
    }

    @MainActor
    private func delete(_ prompt: Prompt) {
        guard !prompt.isBuiltIn else { return }
        let id = prompt.id
        Task {
            await model.promptLibrary.removeUserPrompt(id)
            await reload()
            await model.refreshDictationTriggerPrompts()
        }
    }

    enum SortOption: CaseIterable {
        case builtInFirst, nameAZ, nameZA

        var label: LocalizedStringKey {
            switch self {
            case .builtInFirst: return "Built-in first"
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
                Text(prompt.isBuiltIn ? "Built-in" : "Custom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !prompt.isBuiltIn {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit prompt")
                    .axLeaf("Prompts.Button.Edit")
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete prompt")
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
    var name: String
    var instructions: String
    var triggerWordsText: String
    var assistantMode: Bool

    init(prompt: Prompt) {
        self.id = prompt.id
        self.isExisting = !prompt.name.isEmpty
        self.name = prompt.name
        self.instructions = prompt.instructions
        self.triggerWordsText = prompt.triggerWords.joined(separator: ", ")
        self.assistantMode = !prompt.useSystemInstructions
    }

    var parsedTriggerWords: [String] {
        triggerWordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct PromptEditor: View {
    @Bindable var draft: PromptEditDraft
    let onCommit: (PromptEditDraft) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.isExisting {
                Text("Edit Prompt").font(.title3.weight(.semibold))
            } else {
                Text("New Prompt").font(.title3.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .axLeaf("PromptEditor.TextField.Name")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.instructions)
                    .font(.subheadline)
                    .frame(minHeight: 160)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.3))
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Trigger words").font(.caption).foregroundStyle(.secondary)
                TextField("summary, recap", text: $draft.triggerWordsText)
                    .textFieldStyle(.roundedBorder)
                    .axLeaf("PromptEditor.TextField.TriggerWords")
                Text("Words that switch to this prompt for one dictation. Separate with commas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Assistant mode", isOn: $draft.assistantMode)
                    .axLeaf("PromptEditor.Toggle.AssistantMode")
                Text("When on, the LLM answers your dictation instead of cleaning it up. Use this for voice Q&A.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .axLeaf("PromptEditor.Button.Cancel")
                Button("Save") { onCommit(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .axLeaf("PromptEditor.Button.Save")
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
