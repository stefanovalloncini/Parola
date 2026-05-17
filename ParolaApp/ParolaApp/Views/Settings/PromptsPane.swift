import SwiftUI
import ParolaCore

struct PromptsPane: View {
    @EnvironmentObject var model: AppModel
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
                isBuiltIn: false
            )
            await model.promptLibrary.updateUserPrompt(updated)
        } else {
            _ = await model.promptLibrary.addUserPrompt(name: trimmed, instructions: draft.instructions)
        }
        await reload()
    }

    @MainActor
    private func delete(_ prompt: Prompt) {
        guard !prompt.isBuiltIn else { return }
        let id = prompt.id
        Task {
            await model.promptLibrary.removeUserPrompt(id)
            await reload()
        }
    }

    enum SortOption: CaseIterable {
        case builtInFirst, nameAZ, nameZA

        var label: String {
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
        SettingRow(prompt.name, isFirst: isFirst) {
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
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete prompt")
                }
            }
        }
    }
}

final class PromptEditDraft: Identifiable, ObservableObject {
    let id: UUID
    let isExisting: Bool
    @Published var name: String
    @Published var instructions: String

    init(prompt: Prompt) {
        self.id = prompt.id
        self.isExisting = !prompt.name.isEmpty
        self.name = prompt.name
        self.instructions = prompt.instructions
    }
}

private struct PromptEditor: View {
    @ObservedObject var draft: PromptEditDraft
    let onCommit: (PromptEditDraft) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isExisting ? "Edit Prompt" : "New Prompt")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
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

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") { onCommit(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
