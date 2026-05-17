import SwiftUI
import ParolaCore

struct SnippetsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            SettingsSection {
                let visible = visibleSnippets
                if model.snippets.isEmpty {
                    HStack {
                        Text("No snippets yet.").foregroundStyle(.secondary).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(16)
                } else if visible.isEmpty {
                    HStack {
                        Text("No snippets match.").foregroundStyle(.secondary).font(.system(size: 13))
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

            Button {
                model.snippets.append(Snippet(trigger: "", replacement: ""))
            } label: {
                Label("Add snippet", systemImage: "plus.circle")
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
        return $model.snippets[idx]
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search snippets…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var placeholderHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Triggers fire on dictated text only; matching is case-insensitive and word-bounded.")
                .font(.system(size: 11))
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

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { snippet.enabled && canEnable },
                        set: { if canEnable { snippet.enabled = $0 } }
                    ))
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
