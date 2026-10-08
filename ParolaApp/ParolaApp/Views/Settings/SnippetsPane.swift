import SwiftUI
import ParolaCore
import ParolaDictation

struct SnippetsPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = RuleListQuery()
    @State private var selection: Snippet.ID?

    var body: some View {
        let visible = visibleSnippets
        return SettingsForm {
            Section {
                if model.snippets.isEmpty {
                    InlineEmptyText("No snippets yet")
                } else if visible.isEmpty {
                    InlineEmptyText("No snippets match.")
                } else {
                    RuleListRows(
                        visible, selection: $selection, leaf: "Snippets.Row", label: { "\($0.trigger) → \($0.replacement)" },
                        removeLabel: "Remove Snippet", onRemove: remove
                    ) { snippet in
                        if let binding = binding(for: snippet.id) {
                            SnippetRow(snippet: binding)
                        }
                    }
                }
                RuleListBar(
                    leafPrefix: "Snippets", addLabel: "Add Snippet", removeLabel: "Remove Snippet",
                    canRemove: visible.contains { $0.id == selection },
                    onAdd: add, onRemove: removeSelected
                ) {
                    Button("Import…") { model.importSnippetsFromFile() }
                        .axLeaf("Snippets.MenuItem.Import")
                    Button("Export…") { model.exportSnippetsToFile() }
                        .disabled(model.snippets.isEmpty)
                        .axLeaf("Snippets.MenuItem.Export")
                }
            } header: {
                if query.showsToolbar(ruleCount: model.snippets.count) {
                    RuleListToolbar(query: $query, placeholder: "Search snippets…", leafPrefix: "Snippets")
                }
            } footer: {
                VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                    Text("Triggers fire on dictated text only; matching is case-insensitive and word-bounded.")
                    Text("These placeholders expand in the replacement text: {{DATE}} · {{TIME}} · {{ISODATE}} · {{CLIPBOARD}}")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ResetPaneButton(scope: .snippets)
        }
    }

    private func add() {
        query.showNewRule()
        let snippet = Snippet(trigger: "", replacement: "")
        model.snippets.append(snippet)
        selection = snippet.id
    }

    private func removeSelected() {
        guard let selection else { return }
        remove(selection)
    }

    private func remove(_ id: Snippet.ID) {
        model.snippets.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    private var visibleSnippets: [Snippet] {
        query.arrange(model.snippets, fields: { [$0.trigger, $0.replacement] }, isEnabled: SnippetRow.isEffectivelyEnabled)
    }

    // Resolved by id on every access: an index captured at render time can go stale
    // when a row is deleted before a pending write lands.
    private func binding(for id: Snippet.ID) -> Binding<Snippet>? {
        guard let current = model.snippets.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.snippets.first(where: { $0.id == id }) ?? current },
            set: { newValue in
                guard let idx = model.snippets.firstIndex(where: { $0.id == id }) else { return }
                model.snippets[idx] = newValue
            }
        )
    }
}

private struct SnippetRow: View {
    @Binding var snippet: Snippet

    private var canEnable: Bool {
        !snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isEffectivelyEnabled(_ snippet: Snippet) -> Bool {
        snippet.enabled && !snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { Self.isEffectivelyEnabled(snippet) },
            set: { if canEnable { snippet.enabled = $0 } }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Use this snippet", isOn: enabledBinding)
                .labelsHidden()
                .disabled(!canEnable)
                .axLeaf("Snippets.Toggle.SnippetEnabled")
            TextField("trigger phrase", text: $snippet.trigger, prompt: Text("trigger phrase"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .selectsRuleRowOnFocus()
                .axLeaf("Snippets.TextField.Trigger")
            Text("→").foregroundStyle(DS.Color.secondaryText)
            TextField("replacement", text: $snippet.replacement, prompt: Text("replacement"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .selectsRuleRowOnFocus()
                .axLeaf("Snippets.TextField.Replacement")
        }
    }
}
