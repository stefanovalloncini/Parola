import SwiftUI
import ParolaCore

struct LibraryListView: View {
    @EnvironmentObject var model: AppModel
    let category: EntryCategory

    @State private var selection: Set<LibraryEntry.ID> = []
    @State private var pendingBulkDelete = false
    @State private var renamingEntry: LibraryEntry?
    @State private var renameDraft: String = ""
    @State private var labelFilter: String?
    @State private var dateRangeFilter: DateRangeFilter = .all
    @State private var entries: [LibraryEntry] = []
    @State private var labelOptions: [String] = []

    private enum DateRangeFilter: String, CaseIterable, Identifiable {
        case all, today, week, month, year
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "Any time"
            case .today: return "Today"
            case .week: return "Last 7 days"
            case .month: return "Last 30 days"
            case .year: return "Last year"
            }
        }
        var cutoff: Date? {
            let cal = Calendar.current
            switch self {
            case .all: return nil
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())
            case .year: return cal.date(byAdding: .year, value: -1, to: Date())
            }
        }
    }

    private func recomputeEntries() {
        let inCategory = model.libraryEntries.filter { $0.category == category }
        entries = inCategory
            .filter { entry in
                guard let labelFilter else { return true }
                return entry.labels.contains { $0.localizedCaseInsensitiveCompare(labelFilter) == .orderedSame }
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

    private func recomputeLabelOptions() {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in model.libraryEntries where entry.category == category {
            for label in entry.labels {
                if seen.insert(label).inserted { ordered.append(label) }
            }
        }
        labelOptions = ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            recomputeEntries()
            recomputeLabelOptions()
        }
        .onChange(of: model.libraryVersion) { _, _ in
            recomputeEntries()
            recomputeLabelOptions()
            selection = selection.intersection(Set(entries.map(\.id)))
        }
        .onChange(of: labelFilter) { _, _ in recomputeEntries() }
        .onChange(of: dateRangeFilter) { _, _ in recomputeEntries() }
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
            isPresented: Binding(
                get: { renamingEntry != nil },
                set: { if !$0 { renamingEntry = nil } }
            )
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
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.regular) {
            Text(headerTitle)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.primaryText)
            if !labelOptions.isEmpty {
                Menu {
                    Button("All labels") { labelFilter = nil }
                    Divider()
                    ForEach(labelOptions, id: \.self) { label in
                        Button(label) { labelFilter = label }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tag")
                        Text(labelFilter ?? "All labels")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(labelFilter == nil ? .secondary : DS.Color.accent)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Menu {
                ForEach(DateRangeFilter.allCases) { option in
                    Button(option.label) { dateRangeFilter = option }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(dateRangeFilter.label)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(dateRangeFilter == .all ? .secondary : DS.Color.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            if !selection.isEmpty {
                Menu {
                    Button("Plain Text (.txt)") { model.bulkExportEntries(ids: selection, format: .txt) }
                    Button("Markdown (.md)") { model.bulkExportEntries(ids: selection, format: .md) }
                    Button("Subtitles (.srt)") { model.bulkExportEntries(ids: selection, format: .srt) }
                    Button("WebVTT (.vtt)") { model.bulkExportEntries(ids: selection, format: .vtt) }
                    Button("CSV (.csv)") { model.bulkExportEntries(ids: selection, format: .csv) }
                    Button("JSON (.json)") { model.bulkExportEntries(ids: selection, format: .json) }
                    Button("JSON Lines (.jsonl)") { model.bulkExportEntries(ids: selection, format: .jsonl) }
                    Button("HTML (.html)") { model.bulkExportEntries(ids: selection, format: .html) }
                } label: {
                    Label("Export \(selection.count)", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                Button(role: .destructive) {
                    pendingBulkDelete = true
                } label: {
                    Label("Delete \(selection.count)", systemImage: "trash")
                }
                .controlSize(.small)
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

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.regular) {
            Image(systemName: emptyIcon)
                .font(.system(size: 48, weight: .regular))
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
                Button {
                    model.startRecording(source: .microphone)
                } label: {
                    Label("Record", systemImage: "mic.fill")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
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
    let sizeBytes: Int64?

    private var languageLabel: String? {
        let code = entry.language.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty else { return nil }
        if let localized = Locale.current.localizedString(forLanguageCode: code) {
            return localized.capitalized
        }
        return code.uppercased()
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
                            .font(.system(size: 9))
                            .foregroundStyle(DS.Color.accent)
                    }
                    Text(entry.title)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.primaryText)
                        .lineLimit(1)
                    if entry.segmentNotes.count > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "note.text")
                                .font(.system(size: 9))
                            Text("\(entry.segmentNotes.count)")
                                .font(.system(size: 10, weight: .medium))
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
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                if let opened = entry.lastOpenedAt {
                    Text("Last opened: \(opened.formatted(.relative(presentation: .named)))")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText.opacity(0.75))
                }
            }
            Spacer()
        }
        .padding(.vertical, DS.Spacing.tight)
        .help(tooltip)
    }
}
