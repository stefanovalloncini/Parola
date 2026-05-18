import SwiftUI
import ParolaCore

struct LibraryListView: View {
    @EnvironmentObject var model: AppModel
    let category: EntryCategory

    @State private var selection: Set<LibraryEntry.ID> = []
    @State private var pendingBulkDelete = false
    @State private var renamingEntry: LibraryEntry?
    @State private var renameDraft: String = ""

    private var entries: [LibraryEntry] {
        model.libraryEntries
            .filter { $0.category == category }
            .sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                return lhs.createdAt > rhs.createdAt
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                List(entries, id: \.id, selection: $selection) { entry in
                    LibraryRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            model.loadEntry(entry.id)
                            model.libraryFilter = nil
                        }
                        .contextMenu {
                            Button("Open") {
                                model.loadEntry(entry.id)
                                model.libraryFilter = nil
                            }
                            Button(entry.pinned ? "Unpin" : "Pin") {
                                model.togglePinned(for: entry.id)
                            }
                            Menu("Move to") {
                                ForEach(EntryCategory.allCases.filter { $0 != entry.category }, id: \.self) { target in
                                    Button(libraryCategoryName(target)) {
                                        model.moveEntry(entry.id, to: target)
                                    }
                                }
                            }
                            Button("Rename…") {
                                renameDraft = entry.title
                                renamingEntry = entry
                            }
                            Button("Delete", role: .destructive) {
                                model.deleteEntry(entry.id)
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: entries.map(\.id)) { _, ids in
            let valid = Set(ids)
            selection = selection.intersection(valid)
        }
        .alert("Delete \(selection.count) entries?", isPresented: $pendingBulkDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { performBulkDelete() }
        } message: {
            Text("They'll move to Recently Deleted.")
        }
        .alert(
            "Rename entry",
            isPresented: Binding(
                get: { renamingEntry != nil },
                set: { if !$0 { renamingEntry = nil } }
            )
        ) {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingEntry = nil }
            Button("Rename") {
                if let id = renamingEntry?.id {
                    model.renameEntry(id, to: renameDraft)
                }
                renamingEntry = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.regular) {
            Text(headerTitle)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.primaryText)
            Spacer()
            if !selection.isEmpty {
                Button(role: .destructive) {
                    pendingBulkDelete = true
                } label: {
                    Label("Delete \(selection.count)", systemImage: "trash")
                }
                .controlSize(.small)
            }
            Text("\(entries.count)")
                .font(DS.Font.captionMono)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.regular)
    }

    private func performBulkDelete() {
        let targets = selection
        selection.removeAll()
        for id in targets {
            model.deleteEntry(id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.regular) {
            Image(systemName: emptyIcon)
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(DS.Color.secondaryText.opacity(0.55))
            Text(emptyTitle)
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerTitle: String {
        switch category {
        case .transcription: return "Transcriptions"
        case .meeting: return "Meetings"
        case .dictation: return "Dictations"
        }
    }

    private var emptyTitle: String {
        switch category {
        case .transcription: return "No transcriptions yet"
        case .meeting: return "No meetings yet"
        case .dictation: return "No dictations yet"
        }
    }

    private var emptyIcon: String {
        switch category {
        case .transcription: return "text.alignleft"
        case .meeting: return "person.2"
        case .dictation: return "text.cursor"
        }
    }
}

private func libraryCategoryName(_ category: EntryCategory) -> String {
    switch category {
    case .transcription: return "Transcriptions"
    case .meeting: return "Meetings"
    case .dictation: return "Dictations"
    }
}

private struct LibraryRow: View {
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if entry.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.Color.accent)
                    }
                    Text(entry.title)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.primaryText)
                        .lineLimit(1)
                }
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer()
        }
        .padding(.vertical, DS.Spacing.tight)
    }
}
