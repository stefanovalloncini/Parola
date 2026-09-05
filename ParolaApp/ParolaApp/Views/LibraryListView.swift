import SwiftUI
import ParolaCore

enum LibraryEmptyAction {
    case openFile
    case recordMicrophone
    case recordSystemAudio
    case startDictation
}

enum LibraryListContent {
    /// Leads with the action that produces the kind of entry the filter shows, then the fallbacks.
    static func emptyActions(for category: EntryCategory?, features: FeatureSet) -> [LibraryEmptyAction] {
        var actions: [LibraryEmptyAction] = []
        if category == .meeting, features.isEnabled(.meetings) { actions.append(.recordSystemAudio) }
        if category == .dictation, features.isEnabled(.dictation) { actions.append(.startDictation) }
        actions.append(.openFile)
        if category != .meeting, category != .dictation, features.isEnabled(.micRecording) {
            actions.append(.recordMicrophone)
        }
        return actions
    }

    /// The source keys, not `LocalizedStringKey`, so the casing rule can be asserted over them.
    static func emptyTitle(for category: EntryCategory?, isSearch: Bool) -> String {
        if isSearch { return "No Matches" }
        switch category {
        case .transcription: return "No Transcriptions Yet"
        case .meeting: return "No Meetings Yet"
        case .dictation: return "No Dictations Yet"
        case nil: return "No Entries Yet"
        }
    }

    static func rows(
        from entries: [LibraryEntry],
        category: EntryCategory?,
        labelFilter: String?,
        languageFilter: String?,
        dateRange: LibraryDateRangeFilter
    ) -> [LibraryEntry] {
        let cutoff = dateRange.cutoff
        let filtered = entries.filter { entry in
            if let category, entry.category != category { return false }
            if let labelFilter,
               !entry.labels.contains(where: { $0.localizedCaseInsensitiveCompare(labelFilter) == .orderedSame }) {
                return false
            }
            if let languageFilter, LanguageDisplay.code(for: entry.language) != languageFilter { return false }
            if let cutoff, entry.createdAt < cutoff { return false }
            return true
        }
        // The entries arrive in the order the sidebar's sort menu picked; only pinning is layered on top.
        return filtered.filter(\.pinned) + filtered.filter { !$0.pinned }
    }
}

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
    @State private var entries: [LibraryRowDisplay] = []
    @State private var totalsLabel: String = ""
    @State private var labelOptions: [String] = []
    @State private var languageOptions: [String] = []

    @discardableResult
    private func recomputeEntries() -> [LibraryRowDisplay] {
        let computed: [LibraryEntry]
        if let searchResults {
            computed = searchResults
        } else {
            computed = LibraryListContent.rows(
                from: model.libraryEntries,
                category: category,
                labelFilter: labelFilter,
                languageFilter: languageFilter,
                dateRange: dateRangeFilter
            )
        }
        let sizes = model.libraryBundleSizes
        var totalBytes: Int64 = 0
        let displays = computed.map { entry -> LibraryRowDisplay in
            let size = sizes[entry.id]
            totalBytes += size ?? 0
            return LibraryRowDisplay(entry: entry, sizeBytes: size)
        }
        entries = displays
        if totalBytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            totalsLabel = "\(displays.count) · \(size)"
        } else {
            totalsLabel = "\(displays.count)"
        }
        return displays
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
                List(entries, id: \.id, selection: $selection) { row in
                    let entry = row.entry
                    LibraryRow(display: row)
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
                        // List(.inset) indents its rows by 16pt of its own; this lands them on the 24pt gutter.
                        .listRowInsets(EdgeInsets(
                            top: DS.Spacing.tight,
                            leading: DS.Spacing.small,
                            bottom: DS.Spacing.tight,
                            trailing: DS.Spacing.small
                        ))
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
        .onChange(of: model.libraryBundleSizes) { _, _ in recomputeEntries() }
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
        EmptyStateView(systemImage: emptyIcon, title: emptyTitle) {
            let actions = LibraryListContent.emptyActions(for: category, features: model.features)
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                Button {
                    perform(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .buttonStyle(DSPillButtonStyle(kind: index == 0 ? .primary : .secondary))
                .axLeaf(action.axIdentifier)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func perform(_ action: LibraryEmptyAction) {
        switch action {
        case .openFile: model.presentOpenPanel()
        case .recordMicrophone: model.startRecording(source: .microphone)
        case .recordSystemAudio: model.startRecording(source: .systemAudio)
        case .startDictation: model.startDictationFromIntent()
        }
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
        LocalizedStringKey(LibraryListContent.emptyTitle(for: category, isSearch: searchResults != nil))
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

extension LibraryEmptyAction {
    var title: LocalizedStringKey {
        switch self {
        case .openFile: return "Open file…"
        case .recordMicrophone: return "Record"
        case .recordSystemAudio: return "Record System Audio"
        case .startDictation: return "Start Dictation"
        }
    }

    var systemImage: String {
        switch self {
        case .openFile: return "doc.badge.plus"
        case .recordMicrophone: return "mic.fill"
        case .recordSystemAudio: return "waveform.circle.fill"
        case .startDictation: return "text.cursor"
        }
    }

    var axIdentifier: String {
        switch self {
        case .openFile: return "Empty.Button.OpenFile"
        case .recordMicrophone: return "Empty.Button.Record"
        case .recordSystemAudio: return "Empty.Button.RecordSystemAudio"
        case .startDictation: return "Empty.Button.StartDictation"
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
    enum Style {
        case library
        case home
    }

    let display: LibraryRowDisplay
    var style: Style = .library

    @Environment(AppModel.self) private var model
    private var compact: Bool { model.sidebarDensity == "compact" }

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if display.pinned {
                        Image(systemName: "pin.fill")
                            .font(DS.Font.caption2)
                            .foregroundStyle(DS.Color.accent)
                    }
                    Text(display.title)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.primaryText)
                        .lineLimit(1)
                    if display.noteCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "note.text")
                                .font(DS.Font.caption2)
                            Text("\(display.noteCount)")
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
                    Text(display.timestamp)
                    if let duration = display.durationLabel {
                        Text("·")
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
                        Text(duration)
                            .monospacedDigit()
                    }
                    if let size = display.sizeLabel {
                        Text("·")
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
                        Text(size)
                    }
                    if let lang = display.languageLabel {
                        Text("·")
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
                        Text(lang)
                    }
                    if style == .library, !compact, let opened = display.lastOpened {
                        Text("·")
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
                        Text("Last opened: \(opened)")
                    }
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, compact ? DS.Spacing.tight / 2 : DS.Spacing.tight)
        .help(display.tooltip)
    }
}
