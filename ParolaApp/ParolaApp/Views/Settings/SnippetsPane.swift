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
                    HStack {
                        Text("No snippets yet.").foregroundStyle(.secondary).font(.body)
                        Spacer()
                    }
                    .padding(16)
                } else if visible.isEmpty {
                    HStack {
                        Text("No snippets match.").foregroundStyle(.secondary).font(.body)
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
                    model.snippets.append(Snippet(trigger: "", replacement: ""))
                } label: {
                    Label("Add snippet", systemImage: "plus.circle")
                }
                Spacer()
                Button {
                    model.importSnippetsFromFile()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                Button {
                    model.exportSnippetsToFile()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(model.snippets.isEmpty)
            }

            placeholderHelp
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

    private func binding(for id: Snippet.ID) -> Binding<Snippet>? {
        guard let idx = model.snippets.firstIndex(where: { $0.id == id }) else { return nil }
        @Bindable var model = model
        return $model.snippets[idx]
    }

    private var placeholderHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Triggers fire on dictated text only; matching is case-insensitive and word-bounded.")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
            Text("Placeholders: {{DATE}} · {{TIME}} · {{ISODATE}} · {{CLIPBOARD}}")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
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
                    TextField("trigger phrase", text: $snippet.trigger)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Text("→").foregroundStyle(.secondary)
                    TextField("replacement", text: $snippet.replacement)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}
