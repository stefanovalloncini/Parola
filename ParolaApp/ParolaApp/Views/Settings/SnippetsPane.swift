import SwiftUI
import ParolaCore
import ParolaDictation

struct SnippetsPane: View {
    @Environment(AppModel.self) private var model
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchPill(text: $searchText, placeholder: "Search snippets…")

            SettingsSection {
                let visible = visibleSnippets
                if model.snippets.isEmpty {
                    InlineEmptyText("No snippets yet")
                } else if visible.isEmpty {
                    HStack {
                        Text("No snippets match.").foregroundStyle(DS.Color.secondaryText).font(.body)
                        Spacer()
                    }
                    .padding(16)
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
                    searchText = ""
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
                .font(DS.Font.subheadlineMono)
                .foregroundStyle(DS.Color.secondaryText)
                .padding(.horizontal, 4)
            ResetPaneButton(scope: .snippets)
        }
    }

    private var visibleSnippets: [Snippet] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.snippets }
        return model.snippets.filter {
            $0.trigger.lowercased().contains(query) || $0.replacement.lowercased().contains(query)
        }
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

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { snippet.enabled && canEnable },
            set: { if canEnable { snippet.enabled = $0 } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("", isOn: enabledBinding)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}
