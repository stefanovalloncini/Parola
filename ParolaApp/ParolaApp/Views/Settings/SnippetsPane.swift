import SwiftUI
import ParolaCore
import ParolaDictation

struct SnippetsPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = RuleListQuery()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if query.showsToolbar(ruleCount: model.snippets.count) {
                RuleListToolbar(query: $query, placeholder: "Search snippets…", leafPrefix: "Snippets")
            }

            SettingsSection {
                let visible = visibleSnippets
                if model.snippets.isEmpty {
                    InlineEmptyText("No snippets yet")
                } else if visible.isEmpty {
                    HStack {
                        Text("No snippets match.").foregroundStyle(DS.Color.secondaryText).font(DS.Font.body)
                        Spacer()
                    }
                    .padding(DS.Spacing.medium)
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, snippet in
                        if let binding = binding(for: snippet.id) {
                            SnippetRow(snippet: binding, isFirst: idx == 0) {
                                model.snippets.removeAll { $0.id == snippet.id }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    query.showNewRule()
                    model.snippets.append(Snippet(trigger: "", replacement: ""))
                } label: {
                    Label("Add Snippet", systemImage: "plus.circle")
                }
                .axLeaf("Snippets.Button.AddSnippet")
                Spacer()
                Button {
                    model.importSnippetsFromFile()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .axLeaf("Snippets.Button.Import")
                Button {
                    model.exportSnippetsToFile()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(model.snippets.isEmpty)
                .axLeaf("Snippets.Button.Export")
            }

            SettingHelper(text: "Triggers fire on dictated text only; matching is case-insensitive and word-bounded.")
            Text("These placeholders expand in the replacement text: {{DATE}} · {{TIME}} · {{ISODATE}} · {{CLIPBOARD}}")
                .font(DS.Font.mono)
                .foregroundStyle(DS.Color.secondaryText)
                .padding(.horizontal, DS.Spacing.tight)
            ResetPaneButton(scope: .snippets)
        }
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
    let isFirst: Bool
    let onDelete: () -> Void

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
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, DS.Spacing.medium) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("Use this snippet", isOn: enabledBinding)
                        .labelsHidden()
                        .disabled(!canEnable)
                        .axLeaf("Snippets.Toggle.SnippetEnabled")
                    TextField("trigger phrase", text: $snippet.trigger)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .axLeaf("Snippets.TextField.Trigger")
                    Text("→").foregroundStyle(DS.Color.secondaryText)
                    TextField("replacement", text: $snippet.replacement)
                        .textFieldStyle(.roundedBorder)
                        .axLeaf("Snippets.TextField.Replacement")
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .axLeaf("Snippets.Button.Delete")
                }
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.small)
        }
    }
}
