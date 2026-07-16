import SwiftUI
import ParolaCore

struct LibraryListView: View {
    @Environment(AppModel.self) private var model
    let category: EntryCategory?
    var searchResults: [LibraryEntry]? = nil

    @State private var selection: Set<LibraryEntry.ID> = []
    @State private var pendingBulkDelete = false
    @State private var renamingEntry: LibraryEntry?
    @State private var renameDraft: String = ""
    @State private var labelFilter: String?
    @State private var languageFilter: String?
    @State private var dateRangeFilter: LibraryDateRangeFilter = .all
    @State private var entries: [LibraryEntry] = []
    @State private var labelOptions: [String] = []
    @State private var languageOptions: [String] = []
    @ScaledMetric(relativeTo: .largeTitle) private var emptyIconSize: CGFloat = 48

    @discardableResult
    private func recomputeEntries() -> [LibraryEntry] {
        let computed: [LibraryEntry]
        if let searchResults {
            computed = searchResults
        } else {
            computed = model.libraryEntries
                .filter { category == nil || $0.category == category }
                .filter { entry in
                    guard let labelFilter else { return true }
                    return entry.labels.contains { $0.localizedCaseInsensitiveCompare(labelFilter) == .orderedSame }
                }
                .filter { entry in
                    guard let languageFilter else { return true }
                    return LanguageDisplay.code(for: entry.language) == languageFilter
                }
                .filter { entry in
                    guard let cutoff = dateRangeFilter.cutoff else { return true }
                    return entry.createdAt >= cutoff
                }
                .sorted { lhs, rhs in
                    if lhs.pinned != rhs.pinned { return lhs.pinned }
                    return lhs.createdAt > rhs.createdAt
                }
        }
        entries = computed
        return computed
    }

    private func recomputeFilterOptions() {
        var seenLabels = Set<String>()
        var labels: [String] = []
        var seenLanguages = Set<String>()
        var languages: [String] = []
        for entry in model.libraryEntries where category == nil || entry.category == category {
            for label in entry.labels {
                if seenLabels.insert(label).inserted { labels.append(label) }
            }
            if let code = LanguageDisplay.code(for: entry.language), seenLanguages.insert(code).inserted {
                languages.append(code)
            }
        }
        labelOptions = labels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        languageOptions = languages.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                List(entries, id: \.id, selection: $selection) { entry in
                    LibraryRow(entry: entry, sizeBytes: model.libraryBundleSizes[entry.id])
                        .contentShape(Rectangle())
                        .draggable(entry.bundleURL)
                        .onTapGesture(count: 2) {
                            model.loadEntry(entry.id)
                        }
                        .contextMenu {
                            Button("Open") {
                                model.loadEntry(entry.id)
                            }
                            Button(entry.pinned ? "Unpin" : "Pin") {
                                model.togglePinned(for: entry.id)
                            }
                            .accessibilityIdentifier("library.row.\(entry.id).\(entry.pinned ? "unpin" : "pin")")
                            Menu("Move to") {
                                ForEach(EntryCategory.allCases.filter { $0 != entry.category }, id: \.self) { target in
                                    Button(libraryCategoryName(target)) {
                                        model.moveEntry(entry.id, to: target)
                                    }
                                }
                            }
                            .accessibilityIdentifier("library.row.\(entry.id).moveTo")
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([entry.bundleURL])
                            }
                            .accessibilityIdentifier("library.row.\(entry.id).revealInFinder")
                            Button("Rename…") {
                                renameDraft = entry.title
                                renamingEntry = entry
                            }
                            .accessibilityIdentifier("library.row.\(entry.id).rename")
                            Button("Delete", role: .destructive) {
                                model.deleteEntry(entry.id)
                            }
                            .accessibilityIdentifier("library.row.\(entry.id).delete")
                        }
                        .accessibilityIdentifier("library.row.\(entry.id)")
                }
                .listStyle(.inset)
                .tint(DS.Color.accent)
                .onKeyPress(.return) {
                    guard selection.count == 1, let id = selection.first else { return .ignored }
                    model.loadEntry(id)
                    return .handled
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            recomputeEntries()
            recomputeFilterOptions()
        }
        .onChange(of: model.libraryVersion) { _, _ in
            let newEntries = recomputeEntries()
            recomputeFilterOptions()
            selection = selection.intersection(Set(newEntries.map(\.id)))
        }
        .onChange(of: labelFilter) { _, _ in recomputeEntries() }
        .onChange(of: languageFilter) { _, _ in recomputeEntries() }
        .onChange(of: dateRangeFilter) { _, _ in recomputeEntries() }
        .onChange(of: searchResults) { _, _ in
            let newEntries = recomputeEntries()
            selection = selection.intersection(Set(newEntries.map(\.id)))
        }
        .onChange(of: category) { _, _ in
            let newEntries = recomputeEntries()
            recomputeFilterOptions()
            selection = selection.intersection(Set(newEntries.map(\.id)))
        }
        .alert("Delete \(selection.count) entries?", isPresented: $pendingBulkDelete) {
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("alert.bulkDelete.cancel")
            Button("Delete", role: .destructive) { performBulkDelete() }
                .accessibilityIdentifier("alert.bulkDelete.confirm")
        } message: {
            Text("They'll move to Recently Deleted.")
        }
        .alert(
            "Rename entry",
            isPresented: isRenaming
        ) {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingEntry = nil }
                .accessibilityIdentifier("alert.rename.cancel")
            Button("Rename") {
                if let id = renamingEntry?.id {
                    model.renameEntry(id, to: renameDraft)
                }
                renamingEntry = nil
            }
            .accessibilityIdentifier("alert.rename.confirm")
        }
        .axBranch("Library")
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.regular) {
            Text(headerTitle)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.primaryText)
            if searchResults == nil {
                LibraryFilterBar(
                    labelFilter: $labelFilter,
                    languageFilter: $languageFilter,
                    dateRangeFilter: $dateRangeFilter,
                    labelOptions: labelOptions,
                    languageOptions: languageOptions
                )
            }
            Spacer()
            if !selection.isEmpty {
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button("\(format.displayName) (.\(format.fileExtension))") {
                            model.bulkExportEntries(ids: selection, format: format)
                        }
                        .axLeaf("Header.MenuItem.Export\(format.rawValue.capitalized)")
                    }
                } label: {
                    Label("Export \(selection.count)", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .axLeaf("Header.Menu.BulkExport")
                Button(role: .destructive) {
                    pendingBulkDelete = true
                } label: {
                    Label("Delete \(selection.count)", systemImage: "trash")
                }
                .controlSize(.small)
                .axLeaf("Header.Button.BulkDelete")
            }
            Text(totalsLabel)
                .font(DS.Font.captionMono)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.regular)
    }

    private var totalsLabel: String {
        let bytes = entries.reduce(Int64(0)) { acc, entry in
            acc + (model.libraryBundleSizes[entry.id] ?? 0)
        }
        if bytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "\(entries.count) · \(size)"
        }
        return "\(entries.count)"
    }

    private func performBulkDelete() {
        let targets = selection
        selection.removeAll()
        for id in targets {
            model.deleteEntry(id)
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renamingEntry != nil },
            set: { if !$0 { renamingEntry = nil } }
        )
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.regular) {
            Image(systemName: emptyIcon)
                .font(.system(size: emptyIconSize, weight: .regular))
                .foregroundStyle(DS.Color.secondaryText.opacity(0.55))
            Text(emptyTitle)
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.secondaryText)
            HStack(spacing: 10) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Open file…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .axLeaf("Empty.Button.OpenFile")
                Button {
                    model.startRecording(source: .microphone)
                } label: {
                    Label("Record", systemImage: "mic.fill")
                }
                .buttonStyle(.bordered)
                .axLeaf("Empty.Button.Record")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerTitle: LocalizedStringKey {
        if searchResults != nil { return "Search results" }
        switch category {
        case .transcription: return "Transcriptions"
        case .meeting: return "Meetings"
        case .dictation: return "Dictations"
        case nil: return "All"
        }
    }

    private var emptyTitle: LocalizedStringKey {
        if searchResults != nil { return "No matches" }
        switch category {
        case .transcription: return "No transcriptions yet"
        case .meeting: return "No meetings yet"
        case .dictation: return "No dictations yet"
        case nil: return "No entries yet"
        }
    }

    private var emptyIcon: String {
        switch category {
        case .transcription: return "text.alignleft"
        case .meeting: return "person.2"
        case .dictation: return "text.cursor"
        case nil: return searchResults != nil ? "magnifyingglass" : "tray"
        }
    }
}

private func libraryCategoryName(_ category: EntryCategory) -> LocalizedStringKey {
    switch category {
    case .transcription: return "Transcriptions"
    case .meeting: return "Meetings"
    case .dictation: return "Dictations"
    }
}

struct LibraryRow: View {
    let entry: LibraryEntry
    let sizeBytes: Int64?

    @Environment(AppModel.self) private var model
    private var compact: Bool { model.sidebarDensity == "compact" }

    private var languageLabel: String? {
        LanguageDisplay.name(for: entry.language)
    }

    private var tooltip: String {
        var parts: [String] = [entry.title]
        parts.append(entry.createdAt.formatted(date: .long, time: .shortened))
        if !entry.labels.isEmpty {
            parts.append("Labels: \(entry.labels.joined(separator: ", "))")
        }
        if entry.pinned {
            parts.append("Pinned")
        }
        return parts.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if entry.pinned {
                        Image(systemName: "pin.fill")
                            .font(DS.Font.caption2)
                            .foregroundStyle(DS.Color.accent)
                    }
                    Text(entry.title)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.primaryText)
                        .lineLimit(1)
                    if !entry.segmentNotes.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "note.text")
                                .font(DS.Font.caption2)
                            Text("\(entry.segmentNotes.count)")
                                .font(DS.Font.caption2Medium)
                        }
                        .foregroundStyle(DS.Color.accent.opacity(0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(DS.Color.accent.opacity(0.10))
                        )
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let sizeBytes, sizeBytes > 0 {
                        Text("·")
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
                        Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                    }
                    if let lang = languageLabel {
                        Text("·")
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
                        Text(lang)
                    }
                    if !compact, let opened = entry.lastOpenedAt {
                        Text("·")
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
                        Text("Last opened: \(opened.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, compact ? DS.Spacing.tight / 2 : DS.Spacing.tight)
        .help(tooltip)
    }
}
