import SwiftUI
import ParolaCore

struct MacRecentlyDeletedView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingPurge: LibraryEntry.ID?
    @State private var confirmingEmpty = false
    @State private var searchText = ""
    @State private var previews: [LibraryEntry.ID: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if model.deletedEntries.isEmpty {
                empty
            } else if filtered.isEmpty {
                noMatches
            } else {
                list
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .background(DS.Color.surface)
        .confirmationDialog(
            "Delete permanently?",
            isPresented: Binding(
                get: { confirmingPurge != nil },
                set: { if !$0 { confirmingPurge = nil } }
            )
        ) {
            Button("Delete permanently", role: .destructive) {
                if let id = confirmingPurge { model.purgeEntry(id) }
                confirmingPurge = nil
            }
            Button("Cancel", role: .cancel) { confirmingPurge = nil }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Empty Recently Deleted?",
            isPresented: $confirmingEmpty
        ) {
            Button("Empty", role: .destructive) {
                for entry in model.deletedEntries { model.purgeEntry(entry.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(model.deletedEntries.count) items will be deleted for good.")
        }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.regular) {
            Text("Recently Deleted")
                .font(.system(.title2, design: .default, weight: .semibold))
            Spacer(minLength: DS.Spacing.regular)
            searchField
            actionMenu
            emptyTrashButton
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .frame(minWidth: 140, maxWidth: 200)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(PillChrome())
    }

    private var actionMenu: some View {
        Menu {
            Button("Restore All") {
                for entry in model.deletedEntries { model.restoreEntry(entry.id) }
            }
            .disabled(model.deletedEntries.isEmpty)
            Divider()
            Button("Empty Recently Deleted", role: .destructive) {
                confirmingEmpty = true
            }
            .disabled(model.deletedEntries.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 26)
                .background(PillChrome())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    private var emptyTrashButton: some View {
        Button { confirmingEmpty = true } label: {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .background(PillChrome())
        }
        .buttonStyle(.plain)
        .disabled(model.deletedEntries.isEmpty)
        .help("Empty Recently Deleted")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.large, pinnedViews: []) {
                ForEach(grouped, id: \.0) { group in
                    section(title: group.0, entries: group.1)
                }
                footer
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.top, DS.Spacing.regular)
            .padding(.bottom, DS.Spacing.small)
        }
    }

    private func section(title: String, entries: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(title.uppercased())
                .font(.system(.caption, design: .default, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: DS.Spacing.small) {
                ForEach(entries) { entry in
                    DeletedCard(
                        entry: entry,
                        preview: previews[entry.id],
                        onRestore: { model.restoreEntry(entry.id) },
                        onPurge: { confirmingPurge = entry.id },
                        onTap: { model.loadEntry(entry.id) }
                    )
                    .task(id: entry.id) {
                        await loadPreview(for: entry)
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text("Items are removed for good after \(AppModel.trashRetentionDays) days.")
            .font(DS.Font.caption)
            .foregroundStyle(.secondary)
            .padding(.top, DS.Spacing.small)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var empty: some View {
        ContentUnavailableView(
            "Nothing's been deleted",
            systemImage: "trash",
            description: Text("Deleted transcripts appear here for \(AppModel.trashRetentionDays) days.")
        )
    }

    private var noMatches: some View {
        ContentUnavailableView.search(text: searchText)
    }

    private var filtered: [LibraryEntry] {
        guard !searchText.isEmpty else { return model.deletedEntries }
        let q = searchText.lowercased()
        return model.deletedEntries.filter {
            $0.title.lowercased().contains(q)
            || (previews[$0.id]?.lowercased().contains(q) ?? false)
        }
    }

    private var grouped: [(String, [LibraryEntry])] {
        var seen = Set<String>()
        var order: [String] = []
        var bucketed: [String: [LibraryEntry]] = [:]
        for entry in filtered {
            let key = bucket(for: entry.deletedAt)
            if seen.insert(key).inserted { order.append(key) }
            bucketed[key, default: []].append(entry)
        }
        return order.map { ($0, bucketed[$0] ?? []) }
    }

    private func bucket(for date: Date?) -> String {
        guard let date else { return "Unknown" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return "Earlier This Week" }
        if days < 30 { return "Earlier This Month" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    private func loadPreview(for entry: LibraryEntry) async {
        if previews[entry.id] != nil { return }
        let text = await Task.detached { () -> String in
            let bundleURL = entry.bundleURL
            let transcriptURL = bundleURL.appendingPathComponent("transcript.json")
            guard let data = try? Data(contentsOf: transcriptURL),
                  let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
            else { return "" }
            return transcript.text
        }.value
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        previews[entry.id] = trimmed.isEmpty ? "" : String(trimmed.prefix(280))
    }
}

private struct PillChrome: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(DS.Color.surfaceElevated.opacity(0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(DS.Color.separator.opacity(0.4), lineWidth: 0.5)
            )
    }
}

private struct DeletedCard: View {
    let entry: LibraryEntry
    let preview: String?
    let onRestore: () -> Void
    let onPurge: () -> Void
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            categoryBadge

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                        .font(.system(.headline, design: .default, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Spacing.small)
                    if let deletedAt = entry.deletedAt {
                        Text(deletedAt, format: .dateTime.hour().minute())
                            .font(DS.Font.captionMono)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(previewText)
                    .font(.system(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Spacing.regular)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Color.surfaceElevated.opacity(hovered ? 1.0 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Color.separator.opacity(0.5), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovered { hoverActions }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovered = $0 }
        .contextMenu {
            Button { onRestore() } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { onPurge() } label: {
                Label("Delete permanently", systemImage: "trash")
            }
        }
        .animation(.easeInOut(duration: 0.12), value: hovered)
    }

    private var previewText: String {
        if let preview, !preview.isEmpty { return preview }
        if preview == nil { return "Loading preview…" }
        return "No transcript text."
    }

    private var categoryBadge: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(categoryTint.opacity(0.18))
            .overlay(
                Image(systemName: categoryIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(categoryTint)
            )
            .frame(width: 32, height: 32)
    }

    private var hoverActions: some View {
        HStack(spacing: 4) {
            CardIconButton(systemName: "arrow.uturn.backward", help: "Restore", action: onRestore)
            CardIconButton(systemName: "trash", help: "Delete permanently", tint: DS.Color.danger, action: onPurge)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Color.separator.opacity(0.5), lineWidth: 0.5)
        )
        .padding(DS.Spacing.small)
    }

    private var categoryIcon: String {
        switch entry.category {
        case .transcription: return "waveform"
        case .meeting: return "video.fill"
        case .dictation: return "text.bubble.fill"
        }
    }

    private var categoryTint: Color {
        switch entry.category {
        case .transcription: return Color(red: 0.20, green: 0.62, blue: 0.62)
        case .meeting: return Color(red: 0.34, green: 0.62, blue: 0.36)
        case .dictation: return Color(red: 0.82, green: 0.50, blue: 0.18)
        }
    }
}

private struct CardIconButton: View {
    let systemName: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.opacity(hovered ? 1.0 : 0.75))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovered ? DS.Color.surface : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
