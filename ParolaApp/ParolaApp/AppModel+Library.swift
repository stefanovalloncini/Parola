import Foundation
import SwiftUI
import ParolaCore

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case titleAZ
    case titleZA
    case longest
    case shortest
    case lastOpened

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        case .titleAZ: return "Title A→Z"
        case .titleZA: return "Title Z→A"
        case .longest: return "Longest First"
        case .shortest: return "Shortest First"
        case .lastOpened: return "Last Opened"
        }
    }
}

/// A stored title and how it was set, the pair an undone rename puts back.
struct EntryTitle: Equatable, Sendable {
    var title: String?
    var source: TitleSource?
}

/// The list a transcript was opened from, so the toolbar's Back can go there.
enum LibraryOrigin: Equatable {
    case all
    case category(EntryCategory)
    /// A person's own page: the whole library narrowed to them.
    case person(UUID)
    case search

    /// Read off the user's place rather than the lit row, so a search wins over the category filter underneath it.
    static func capture(from page: SidebarSelection.Page) -> LibraryOrigin? {
        guard page.route == .transcript else { return nil }
        if page.searching { return .search }
        switch SidebarSelection.place(of: page) {
        case .library?: return page.listShowing ? .all : nil
        case .category(let category)?: return .category(category)
        case .person(let id)?: return .person(id)
        case .recording?, .activity?, .recentlyDeleted?, nil: return nil
        }
    }

    var bridgeName: String {
        switch self {
        case .all: return "all"
        case .category(let category): return category.rawValue
        case .person: return "person"
        case .search: return "search"
        }
    }
}

struct LibraryCounts: Equatable {
    private(set) var total = 0
    private var byCategory: [EntryCategory: Int] = [:]

    init(_ entries: [LibraryEntry] = []) {
        total = entries.count
        for entry in entries { byCategory[entry.category, default: 0] += 1 }
    }

    func count(of category: EntryCategory) -> Int {
        byCategory[category] ?? 0
    }
}

struct LabelWrite {
    let sequence: Int
    let write: Task<Void, Never>
    let settled: Task<Void, Never>
}

/// One change to an entry's label list; applying it yields the change that undoes it.
enum LabelEdit {
    case add(String)
    case insert(String, at: Int)
    case remove(String)

    func apply(to labels: inout [String]) -> LabelEdit? {
        switch self {
        case .add(let label):
            guard !labels.contains(where: { $0.localizedCaseInsensitiveCompare(label) == .orderedSame }) else { return nil }
            labels.append(label)
            return .remove(label)
        case .insert(let label, let index):
            guard !labels.contains(where: { $0.localizedCaseInsensitiveCompare(label) == .orderedSame }) else { return nil }
            labels.insert(label, at: min(index, labels.count))
            return .remove(label)
        case .remove(let label):
            guard let index = labels.firstIndex(of: label) else { return nil }
            labels.remove(at: index)
            return .insert(label, at: index)
        }
    }
}

extension AppModel {

    func refreshLibrary() {
        libraryRefreshes &+= 1
        libraryRefreshTask?.cancel()
        libraryRefreshTask = Task { [weak self] in
            guard let self else { return }
            guard let snapshot = await readLibrarySnapshot() else { return }
            setDeletedEntries(snapshot.deleted)
            refreshBundleSizes(for: snapshot.active)
            if setLibraryEntries(sortedLibraryEntries(snapshot.active)) { refreshSearchResults() }
            if !libraryLoaded { libraryLoaded = true }
            refreshLibraryExcerpts()
        }
    }

    /// nil once a later refreshLibrary() has cancelled this one: its snapshot may predate a mutation, so it must not overwrite the newer result.
    private func readLibrarySnapshot() async -> (active: [LibraryEntry], deleted: [LibraryEntry])? {
        while true {
            let edits = libraryLocalEdits
            let active = await library.list()
            let deleted = await library.listDeleted()
            if Task.isCancelled { return nil }
            // A row landed or patched while the store was read is newer than the snapshot: read again instead of putting the snapshot back over it.
            if edits == libraryLocalEdits { return (active, deleted) }
        }
    }

    /// Picks up what the MCP server or the CLI saved into the library while the app was in the background.
    @discardableResult
    func refreshLibraryIfChangedElsewhere() -> Task<Void, Never> {
        Task { [weak self, library] in
            guard await library.folderChangedElsewhere() else { return }
            await library.dropCaches()
            self?.refreshLibrary()
        }
    }

    /// `refreshLibrary()` is fire-and-forget; this awaits the scan so a caller sees `libraryEntries` updated before it returns.
    func refreshLibraryAndWait() async {
        refreshLibrary()
        // A newer refresh started after this caller's write, so it is joined: waiters restarting each other never settled.
        while let task = libraryRefreshTask, !Task.isCancelled {
            await task.value
            if !task.isCancelled { return }
            // A finished task a newer refresh cancelled reads as cancelled too, so only one nothing replaced restarts.
            if libraryRefreshTask == task { refreshLibrary() }
        }
    }

    /// Rows quote a transcript's first lines; the index cuts them as it indexes and names each set with a generation.
    func refreshLibraryExcerpts() {
        libraryExcerptsTask?.cancel()
        let known = libraryExcerptsGeneration
        libraryExcerptsTask = Task { [weak self] in
            guard let self else { return }
            guard let excerpts = await library.excerpts(after: known) else { return }
            guard !Task.isCancelled else { return }
            libraryExcerptsGeneration = excerpts.generation
            libraryExcerpts = excerpts.byEntry
        }
    }

    /// A refresh runs on every library touch, most of which change nothing, and reassigning anyway repaints every reader.
    @discardableResult
    func setLibraryEntries(_ entries: [LibraryEntry]) -> Bool {
        guard !Self.sameEntries(entries, libraryEntries, comparingLastOpened: librarySortOrder == .lastOpened) else { return false }
        libraryEntries = entries
        return true
    }

    /// A refresh differing only in `lastOpenedAt` is masked out, so its writer patches the row here.
    func patchLibraryEntry(id: LibraryEntry.ID, _ edit: (inout ParolaDocument.Manifest) -> Void) {
        guard let index = libraryEntries.firstIndex(where: { $0.id == id }) else { return }
        let current = libraryEntries[index]
        var manifest = current.manifest
        edit(&manifest)
        guard manifest != current.manifest else { return }
        libraryEntries[index] = LibraryEntry(
            id: current.id, bundleURL: current.bundleURL, manifest: manifest
        )
        libraryLocalEdits &+= 1
    }

    /// One assignment for an entry that just landed: its row patched, or inserted where the sort puts it, with no rescan.
    /// The unsaved transcript on screen has just been saved as `entryID`: it takes the selection, and
    /// the AI runs asked for it before the save follow it into the entry.
    func selectLanded(_ entryID: LibraryEntry.ID) {
        selectedEntryID = entryID
        aiJobs.adoptUnsaved(as: entryID)
    }

    func landLibraryEntry(_ entry: LibraryEntry) {
        var entries = libraryEntries
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            guard entries[index].manifest != entry.manifest else { return }
            entries[index] = entry
            if librarySortOrder == .titleAZ || librarySortOrder == .titleZA {
                entries = sortedLibraryEntries(entries)
            }
            libraryEntries = entries
        } else {
            guard entry.deletedAt == nil else { return }
            // In front, so the sort keeps it ahead of anything made the same second, as the store does.
            entries = sortedLibraryEntries([entry] + entries)
            libraryEntries = entries
            refreshBundleSizes(for: entries)
            refreshLibraryExcerpts()
        }
        libraryLocalEdits &+= 1
        refreshSearchResults()
    }

    func setDeletedEntries(_ entries: [LibraryEntry]) {
        guard !Self.sameEntries(entries, deletedEntries, comparingLastOpened: false) else { return }
        deletedEntries = entries
    }

    /// LibraryEntry equality is id-only, so a rename or a pin would slip through without comparing manifests; `lastOpenedAt` alone counts only where the sort reads it.
    static func sameEntries(_ lhs: [LibraryEntry], _ rhs: [LibraryEntry], comparingLastOpened: Bool) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in
            guard left.id == right.id else { return false }
            if left.manifest == right.manifest { return true }
            guard !comparingLastOpened else { return false }
            var masked = right.manifest
            masked.lastOpenedAt = left.manifest.lastOpenedAt
            return left.manifest == masked
        }
    }

    func reapplyLibrarySort() {
        libraryEntries = sortedLibraryEntries(libraryEntries)
    }

    /// Keyed once per entry: the displayed title runs a regex, and a comparator would run it per comparison.
    private func entriesSortedByTitle(_ entries: [LibraryEntry], ascending: Bool) -> [LibraryEntry] {
        entries
            .map { (title: LibraryEntryDisplay.listTitle(for: $0, showsAITitle: showAITitles), entry: $0) }
            .sorted {
                let order = $0.title.localizedCaseInsensitiveCompare($1.title)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            .map(\.entry)
    }

    func sortedLibraryEntries(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        switch librarySortOrder {
        case .newest:
            return entries.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return entries.sorted { $0.createdAt < $1.createdAt }
        case .titleAZ:
            return entriesSortedByTitle(entries, ascending: true)
        case .titleZA:
            return entriesSortedByTitle(entries, ascending: false)
        case .longest:
            return entries.sorted { ($0.durationSeconds ?? 0) > ($1.durationSeconds ?? 0) }
        case .shortest:
            return entries.sorted { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
        case .lastOpened:
            return entries.sorted { lhs, rhs in
                switch (lhs.lastOpenedAt, rhs.lastOpenedAt) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.createdAt > rhs.createdAt
                }
            }
        }
    }

    private func refreshBundleSizes(for entries: [LibraryEntry]) {
        let knownSizes = libraryBundleSizes
        let activeIDs = Set(entries.map(\.id))
        let needsScan = entries.filter { knownSizes[$0.id] == nil }
        guard !needsScan.isEmpty || knownSizes.keys.contains(where: { !activeIDs.contains($0) }) else { return }
        let bundles = needsScan.map { (id: $0.id, url: $0.bundleURL, audioFilename: $0.manifest.audioFilename) }
        Task { [weak self] in
            guard let newSizes = try? await AppModel.offMainIO(qos: .utility, {
                var sizes: [String: Int64] = [:]
                for bundle in bundles {
                    sizes[bundle.id] = AppModel.audioSize(inBundle: bundle.url, named: bundle.audioFilename)
                }
                return sizes
            }) else { return }
            guard let self else { return }
            var merged = self.libraryBundleSizes.filter { activeIDs.contains($0.key) }
            merged.merge(newSizes) { _, new in new }
            self.libraryBundleSizes = merged
        }
    }

    /// Bundles written before the manifest carried `audioFilename` need the directory listing to find their audio.
    nonisolated static func audioSize(inBundle bundleURL: URL, named audioFilename: String?) -> Int64 {
        func size(of url: URL) -> Int64? {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let bytes = values.fileSize else { return nil }
            return Int64(bytes)
        }
        if let audioFilename, !audioFilename.isEmpty,
           let bytes = size(of: bundleURL.appendingPathComponent(audioFilename)) {
            return bytes
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        // Same tie-break as ParolaDocument.read, so the size matches the audio the entry actually plays.
        let audio = contents
            .filter { $0.lastPathComponent.hasPrefix("audio.") }
            .min { $0.lastPathComponent < $1.lastPathComponent }
        guard let audio else { return 0 }
        return size(of: audio) ?? 0
    }

    func labels(for id: LibraryEntry.ID) -> [String] {
        pendingLabels[id] ?? libraryEntry(id: id)?.labels ?? []
    }

    /// False when the label is blank or the entry already carries it in any casing.
    @discardableResult
    func addLabel(_ label: String, to id: LibraryEntry.ID) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return applyLabelEdit(.add(trimmed), to: id, actionName: String(localized: "Add Label"))
    }

    func removeLabel(_ label: String, from id: LibraryEntry.ID) {
        applyLabelEdit(.remove(label), to: id, actionName: String(localized: "Remove Label"))
    }

    @discardableResult
    private func applyLabelEdit(_ edit: LabelEdit, to id: LibraryEntry.ID, actionName: String) -> Bool {
        var next = labels(for: id)
        guard let inverse = edit.apply(to: &next) else { return false }
        registerUndoStep(actionName: actionName) { $0.applyLabelEdit(inverse, to: id, actionName: actionName) }
        writeLabels(next, for: id)
        return true
    }

    /// Writes queue behind each other and nothing else; one library refresh follows the last of a burst, and the list stays pending until it lands.
    private func writeLabels(_ labels: [String], for id: LibraryEntry.ID) {
        pendingLabels[id] = labels
        patchLibraryEntry(id: id) { $0.labels = labels }
        let previous = labelWrites[id]
        let sequence = (previous?.sequence ?? 0) &+ 1
        let write = Task { [weak self] in
            await previous?.write.value
            guard let self else { return }
            do {
                try await library.setLabels(labels, for: id)
            } catch {
                noteLibraryFailure(String(localized: "Couldn't update labels"), error)
            }
        }
        let settled = Task { [weak self] in
            await write.value
            guard let self, labelWrites[id]?.sequence == sequence else { return }
            await refreshLibraryAndWait()
            guard labelWrites[id]?.sequence == sequence else { return }
            labelWrites[id] = nil
            pendingLabels[id] = nil
        }
        labelWrites[id] = LabelWrite(sequence: sequence, write: write, settled: settled)
    }

    func awaitLabelWrites(for id: LibraryEntry.ID) async {
        await labelWrites[id]?.settled.value
    }

    func moveEntry(_ id: LibraryEntry.ID, to category: EntryCategory) {
        moveEntries([id], to: category)
    }

    func moveEntries(_ ids: [LibraryEntry.ID], to category: EntryCategory) {
        let old = knownValues(of: ids) { $0.category }
        applyCategories(Dictionary(ids.map { ($0, category) }) { first, _ in first }, replacing: old)
    }

    /// Both values travel with the step, so undo and redo never read a cache a refresh is about to replace.
    private func applyCategories(_ new: [LibraryEntry.ID: EntryCategory], replacing old: [LibraryEntry.ID: EntryCategory]) {
        if old.contains(where: { new[$0.key] != $0.value }) {
            registerUndoStep(actionName: String(localized: "Move")) { $0.applyCategories(old, replacing: new) }
        }
        Task { [weak self] in
            guard let self else { return }
            for (id, category) in new {
                do {
                    try await library.setCategory(category, for: id)
                } catch {
                    noteLibraryFailure(String(localized: "Couldn't move"), error)
                }
            }
            refreshLibrary()
        }
    }

    func togglePinned(for id: LibraryEntry.ID) {
        setPinned(!(libraryEntry(id: id)?.pinned ?? false), for: [id])
    }

    func setPinned(_ pinned: Bool, for ids: [LibraryEntry.ID]) {
        let old = knownValues(of: ids) { $0.pinned }
        let actionName = pinned ? String(localized: "Pin") : String(localized: "Unpin")
        applyPins(Dictionary(ids.map { ($0, pinned) }) { first, _ in first }, replacing: old, actionName: actionName)
    }

    private func applyPins(_ new: [LibraryEntry.ID: Bool], replacing old: [LibraryEntry.ID: Bool], actionName: String) {
        if old.contains(where: { new[$0.key] != $0.value }) {
            registerUndoStep(actionName: actionName) { $0.applyPins(old, replacing: new, actionName: actionName) }
        }
        Task { [weak self] in
            guard let self else { return }
            for (id, pinned) in new {
                do {
                    try await library.setPinned(pinned, for: id)
                } catch {
                    noteLibraryFailure(pinned ? String(localized: "Couldn't pin") : String(localized: "Couldn't unpin"), error)
                }
            }
            refreshLibrary()
        }
    }

    func renameEntry(_ id: LibraryEntry.ID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let old = libraryEntry(id: id).map { EntryTitle(title: $0.manifest.title, source: $0.manifest.titleSource) }
        applyTitle(EntryTitle(title: trimmed, source: .user), replacing: old, for: id)
    }

    private func applyTitle(_ new: EntryTitle, replacing old: EntryTitle?, for id: LibraryEntry.ID) {
        if let old, old != new {
            registerUndoStep(actionName: String(localized: "Rename")) { $0.applyTitle(old, replacing: new, for: id) }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.restoreTitle(new.title, source: new.source, for: id)
            } catch {
                noteLibraryFailure(String(localized: "Couldn't rename"), error)
            }
            refreshLibrary()
        }
    }

    var canRenameOpenTranscript: Bool { mainTranscriptCommandsEnabled && selectedEntryID != nil }

    func renameOpenTranscript(to newName: String) {
        guard let id = selectedEntryID else { return }
        renameEntry(id, to: newName)
    }

    /// Only rows the library knows, so an undo never invents a value for an entry it never saw.
    private func knownValues<Value>(
        of ids: [LibraryEntry.ID], _ value: (LibraryEntry) -> Value
    ) -> [LibraryEntry.ID: Value] {
        var values: [LibraryEntry.ID: Value] = [:]
        for id in ids {
            if let entry = libraryEntry(id: id) { values[id] = value(entry) }
        }
        return values
    }

    func beginEditingNote(for segment: TranscriptSegment) {
        guard let entryID = selectedEntryID else { return }
        editingSegmentNote = SegmentNoteTarget(
            entryID: entryID, segment: segment, note: currentSegmentNote(for: segment.id)
        )
    }

    func setSegmentNote(_ note: String?, segmentID: Int) {
        let stored = Self.storedNote(note)
        let previous = currentSegmentNote(for: segmentID)
        guard stored != previous else { return }
        let actionName = stored == nil ? String(localized: "Delete Note") : String(localized: "Edit Note")
        applySegmentNote(stored, replacing: previous, segmentID: segmentID, actionName: actionName)
    }

    static func storedNote(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Both values travel with the step, so undo and redo never read a cache a refresh is about to replace.
    private func applySegmentNote(_ note: String?, replacing previous: String?, segmentID: Int, actionName: String) {
        guard let entryID = selectedEntryID else { return }
        patchLibraryEntry(id: entryID) { $0.segmentNotes[String(segmentID)] = note }
        registerUndoStep(actionName: actionName) { model in
            guard model.selectedEntryID == entryID else { return }
            model.applySegmentNote(previous, replacing: note, segmentID: segmentID, actionName: actionName)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.setSegmentNote(note, segmentID: segmentID, for: entryID)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            refreshLibrary()
        }
    }

    /// The notes of the selected entry keyed the way the transcript keys its segments.
    var segmentNotesByID: [Int: String] {
        guard let id = selectedEntryID, let entry = libraryEntry(id: id) else { return [:] }
        return Dictionary(
            entry.segmentNotes.compactMap { key, value in Int(key).map { ($0, value) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Writes the whole note map, for an edit that renumbered the segments it is keyed by.
    func replaceSegmentNotes(_ notes: [Int: String]) {
        guard let entryID = selectedEntryID else { return }
        let stored = Dictionary(
            notes.map { (String($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        patchLibraryEntry(id: entryID) { $0.segmentNotes = stored }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.setSegmentNotes(stored, for: entryID)
            } catch {
                nonFatalWarning = error.localizedDescription
            }
            refreshLibrary()
        }
    }

    func currentSegmentNote(for segmentID: Int) -> String? {
        selectedEntryNotes[String(segmentID)]
    }

    var favoriteSegmentIDs: Set<Int> { selectedEntryFavorites }

    func isSegmentFavorite(_ id: Int) -> Bool {
        selectedEntryFavorites.contains(id)
    }

    /// The single write path for a segment's favorite, shared by the UI toggle and the bridge; nil means no entry is selected.
    @discardableResult
    func setSegmentFavorite(_ id: Int, isFavorite: Bool) async throws -> Bool? {
        guard let entryID = selectedEntryID else { return nil }
        clearFavoritesOnlyIfEmptied(unfavoriting: id, isFavorite: isFavorite)
        try await library.setSegmentFavorite(isFavorite, segmentID: id, for: entryID)
        await refreshLibraryAndWait()
        return isSegmentFavorite(id)
    }

    func toggleSegmentFavorite(_ id: Int) {
        guard selectedEntryID != nil else { return }
        let makeFavorite = !isSegmentFavorite(id)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await setSegmentFavorite(id, isFavorite: makeFavorite)
            } catch {
                nonFatalWarning = error.localizedDescription
            }
        }
    }

    private func clearFavoritesOnlyIfEmptied(unfavoriting id: Int, isFavorite: Bool) {
        guard !isFavorite, favoritesOnly, favoriteSegmentIDs.subtracting([id]).isEmpty else { return }
        favoritesOnly = false
    }

    /// The highlighted segment, the one playing or last clicked; never one the user can't see chosen.
    var focusedSegmentIDForCommands: Int? {
        transcript == nil ? nil : currentSegmentID
    }

    func replaceFavorites(_ ids: Set<Int>) {
        guard let entryID = selectedEntryID else { return }
        if ids.isEmpty, favoritesOnly { favoritesOnly = false }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.setFavoriteSegments(ids, for: entryID)
            } catch {
                nonFatalWarning = error.localizedDescription
            }
            refreshLibrary()
        }
    }

    func deleteEntry(_ id: LibraryEntry.ID) {
        deleteEntries([id])
    }

    func deleteEntries(_ ids: [LibraryEntry.ID]) {
        setDeleted(true, ids, actionName: String(localized: "Delete"))
    }

    func restoreEntry(_ id: LibraryEntry.ID) {
        restoreEntries([id])
    }

    func restoreEntries(_ ids: [LibraryEntry.ID]) {
        setDeleted(false, ids, actionName: String(localized: "Restore"))
    }

    private func setDeleted(_ deleted: Bool, _ ids: [LibraryEntry.ID], actionName: String) {
        guard !ids.isEmpty else { return }
        // Closing the loaded transcript empties the undo stack, so a delete that closes it registers afterwards.
        let closesLoadedEntry = deleted && selectedEntryID.map { ids.contains($0) } == true
        if !closesLoadedEntry { registerSetDeletedUndo(deleted, ids, actionName: actionName) }
        Task { [weak self] in
            guard let self else { return }
            for id in ids {
                if deleted {
                    await moveToRecentlyDeleted(id)
                } else {
                    do {
                        try await library.restore(id)
                    } catch {
                        noteLibraryFailure(String(localized: "Couldn't restore"), error)
                    }
                }
            }
            if closesLoadedEntry { registerSetDeletedUndo(deleted, ids, actionName: actionName) }
            refreshLibrary()
        }
    }

    private func registerSetDeletedUndo(_ deleted: Bool, _ ids: [LibraryEntry.ID], actionName: String) {
        registerUndoStep(actionName: actionName) { $0.setDeleted(!deleted, ids, actionName: actionName) }
    }

    private func moveToRecentlyDeleted(_ id: LibraryEntry.ID) async {
        aiJobs.cancelAll(for: id)
        do {
            try await library.delete(id)
            if selectedEntryID == id { clearLoadedEntry() }
            if destinationsEnabled { await deliveryEngine.cancel(entryID: id) }
        } catch {
            noteLibraryFailure(String(localized: "Couldn't delete"), error)
        }
    }

    func purgeEntry(_ id: LibraryEntry.ID) {
        Task { [weak self] in
            guard let self else { return }
            aiJobs.cancelAll(for: id)
            do {
                try await library.purge(id)
                if selectedEntryID == id { clearLoadedEntry() }
                if destinationsEnabled { await deliveryEngine.cancel(entryID: id) }
            } catch {
                noteLibraryFailure(String(localized: "Couldn't permanently delete"), error)
            }
            refreshLibrary()
        }
    }

    /// Shows the failure as a dismissible strip over whatever page the user is on.
    private func noteLibraryFailure(_ action: String, _ error: Error) {
        exportNotice = ExportNotice(message: "\(action): \(error.localizedDescription)", failures: [], folder: nil, tone: .failure)
    }

    func clearLoadedEntry() {
        pendingTranscriptSaveTask?.cancel()
        pendingTranscriptSaveTask = nil
        clearDerivedArtifacts()
        selectedEntryID = nil
        transcript = nil
        sourceFileURL = nil
        favoritesOnly = false
        transcriptPaneMode = .transcript
        tearDownPlayer()
        if case .ready = phase { phase = .idle }
    }

    func bulkExportEntries(ids: Set<LibraryEntry.ID>, format: ExportFormat) {
        guard !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export here")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let entriesByID = Dictionary(uniqueKeysWithValues: libraryEntries.map { ($0.id, $0) })
        let targets = ids.compactMap { entriesByID[$0] }
        Task { [weak self] in
            guard let self else { return }
            exportNotice = await exportEntries(targets, format: format, to: folder)
        }
    }

    /// Keeps going past a failure: the notice counts what landed and names what didn't.
    func exportEntries(_ entries: [LibraryEntry], format: ExportFormat, to folder: URL) async -> ExportNotice {
        let exporter = makeExporter(for: format)
        var usedNames = Set<String>()
        var failures: [ExportNotice.Failure] = []
        for entry in entries {
            do {
                let loaded = try await library.load(entry.id)
                let transcript = loaded.document.transcript
                let safe = TranscriptShareFile.safeName(for: LibraryEntryDisplay.listTitle(for: entry, showsAITitle: showAITitles))
                var name = safe
                var suffix = 2
                while usedNames.contains(name) {
                    name = "\(safe) (\(suffix))"
                    suffix += 1
                }
                usedNames.insert(name)
                let url = folder.appendingPathComponent("\(name).\(format.fileExtension)")
                try await AppModel.offMainIO {
                    let data = try exporter.render(transcript)
                    try data.write(to: url, options: .atomic)
                    OutputMarker.mark(url)
                }
            } catch {
                // An entry id is <timestamp>-<uuid>; only the uuid half is loggable.
                var fields: [LogField: LogValue] = [.error: .error(error)]
                if let uuid = UUID(uuidString: String(entry.id.suffix(36))) {
                    fields[.entry] = .id(uuid)
                }
                ParolaLog.error(.export, "library export failed as \(format)", fields)
                failures.append(
                    ExportNotice.Failure(
                        name: LibraryEntryDisplay.listTitle(for: entry, showsAITitle: showAITitles),
                        reason: error.localizedDescription
                    )
                )
            }
        }
        return .bulk(exported: entries.count - failures.count, of: entries.count, failures: failures, folder: folder)
    }

    /// Opens an entry into the main pane, whatever else is running (a take keeps recording on its own page); returns the open for a caller that waits on it.
    @discardableResult
    func loadEntry(_ id: LibraryEntry.ID) -> Task<Transcript, any Error> {
        startOpeningEntry(id)
    }

    /// `loadEntry` for a caller that needs what it opened; a later open makes this one throw `CancellationError`.
    @discardableResult
    func openEntry(_ id: LibraryEntry.ID) async throws -> Transcript {
        try await startOpeningEntry(id).value
    }

    @discardableResult
    private func startOpeningEntry(_ id: LibraryEntry.ID) -> Task<Transcript, any Error> {
        leaveFailedPhase()
        introduction.defer()
        loadEntryGeneration &+= 1
        let generation = loadEntryGeneration
        // Read before the transcript takes the content area, which is what hides the list it came from.
        let origin = captureLibraryOrigin()
        let pageAtStart = route
        let hit = searchRanking == nil ? nil : searchQuery.trimmingCharacters(in: .whitespaces)
        let hitPosition = searchMatches[id]?.firstHit
        return Task { [weak self] in
            guard let self else { throw CancellationError() }
            await flushPendingTranscriptSave()
            do {
                let loaded = try await library.load(id)
                // Two quick clicks race across the await, and the slower load would land last.
                guard generation == loadEntryGeneration else { throw CancellationError() }
                // Recently Deleted reads trashed bundles on purpose; opening one here would send its edits into the trash.
                guard loaded.entry.deletedAt == nil else { throw LibraryStore.LibraryError.inTrash(id) }
                // Opened before the library's list has it, as Spotlight or Shortcuts can at launch: Transcribe Again and the title read the list.
                if libraryEntry(id: id) == nil { landLibraryEntry(loaded.entry) }
                installStoredTranscript(loaded.document.transcript)
                closeFind()
                sourceFileURL = loaded.document.audioURL
                selectedEntryID = id
                favoritesOnly = false
                if let audioURL = loaded.document.audioURL {
                    installPlayer(for: audioURL)
                    adoptLoadedMediaDuration()
                } else {
                    tearDownPlayer()
                }
                phase = .ready
                // Opened from the extra, a link or the duplicate sheet it would load behind a page; a page opened during the load is the later word.
                if route == pageAtStart { route = .transcript }
                libraryOrigin = origin
                libraryOriginEntryID = id
                if let hit, !hit.isEmpty { revealInTranscript(hit, at: hitPosition) }
                let opened = transcript ?? loaded.document.transcript
                let openedAt = Date()
                if (try? await library.markOpened(id: id, at: openedAt)) != nil {
                    patchLibraryEntry(id: id) { $0.lastOpenedAt = openedAt }
                }
                refreshLibrary()
                return opened
            } catch {
                guard generation == loadEntryGeneration else { throw error }
                phase = .failed(message: error.localizedDescription)
                throw error
            }
        }
    }

    /// The Library page with every entry on it; it only shows with nothing loaded, so the transcript has to go.
    func goHome() {
        leaveFailedPhase()
        libraryFilter = nil
        personFilter = nil
        showList()
    }

    func browseAll() {
        goHome()
    }

    func browseCategory(_ category: EntryCategory) {
        leaveFailedPhase()
        libraryFilter = category
        personFilter = nil
        showList()
    }

    /// Not `dismissError()`: that also cancels an in-flight yt-dlp update, which navigating away must not do.
    func leaveFailedPhase() {
        guard case .failed(let message) = phase else { return }
        // The banner only ever renders on .transcript, on the browse list and the results alike; anywhere else this failure was never shown.
        if route != .transcript { postFailureNotice(message) }
        phase = transcript == nil ? .idle : .ready
    }

    /// The strip a failure moves to when whatever showed it is about to be replaced.
    func postFailureNotice(_ message: String) {
        exportNotice = ExportNotice(message: message, failures: [], folder: nil, tone: .failure)
    }

    /// Results outrank every list, so anything that leaves one has to retire the query that would mask it.
    func leaveList(keepingTranscript: Bool) {
        clearSearch()
        forgetLibraryOrigin()
        if !keepingTranscript { closeTranscript() }
    }

    private func showList() {
        leaveList(keepingTranscript: false)
        route = .transcript
    }

    func forgetLibraryOrigin() {
        libraryOrigin = nil
        libraryOriginEntryID = nil
    }

    /// The transcript toolbar's Back: leaves the list the entry was opened from exactly as it was.
    func returnToOrigin() {
        switch transcriptOrigin {
        case .category(let category):
            libraryFilter = category
        case .all:
            libraryFilter = nil
        case .person(let id):
            libraryFilter = nil
            personFilter = person(id: id) != nil ? id : nil
        case .search:
            break
        case nil:
            libraryFilter = nil
            personFilter = nil
            clearSearch()
        }
        forgetLibraryOrigin()
        route = .transcript
        closeTranscript()
    }

    /// Nil when no list is behind the transcript: a page of its own, a batch, or the Library page with something already loaded.
    func captureLibraryOrigin() -> LibraryOrigin? {
        LibraryOrigin.capture(from: sidebarPage)
    }

    var sidebarPage: SidebarSelection.Page {
        SidebarSelection.Page(
            route: route,
            listShowing: isBrowsingLibrary,
            searching: hasSearchResults,
            libraryFilter: libraryFilter,
            personFilter: personFilter
        )
    }

    /// Flush first, so a debounced edit from the last second still reaches the library.
    func closeTranscript() {
        guard transcriptRoutePhase == .ready, transcript != nil else { return }
        transcriptCloseTask = Task { [weak self] in
            await self?.flushPendingTranscriptSave()
            self?.clearLoadedEntry()
        }
    }

    /// A navigation's list shows only once the transcript over it has closed, which `closeTranscript()` does after a flush.
    func awaitTranscriptClose() async {
        await transcriptCloseTask?.value
    }

    func openStatistics() {
        openPage(.statistics, keepingTranscript: false)
    }

    func openRecentlyDeleted() {
        openPage(.recentlyDeleted, keepingTranscript: false)
    }

    /// A batch opens this page on its own when it starts or grows, so it leaves what is loaded alone.
    func openQueue() {
        openPage(.queue, keepingTranscript: true)
    }

    func openBatch() {
        openPage(.batch, keepingTranscript: true)
    }

    /// Opens the settings window on a specific pane — the one place a route is picked before the window opens.
    func openSettings(route: SettingsRoute) {
        commitPaletteDraft()
        settingsPane = route.rawValue
        showSettingsWindow()
    }

    func showSettingsWindow() {
        settingsWindowOpener?()
    }

    private func openPage(_ page: Route, keepingTranscript: Bool) {
        leaveFailedPhase()
        leaveList(keepingTranscript: keepingTranscript)
        libraryFilter = nil
        personFilter = nil
        route = page
    }

    /// The library is the stand-in destination until routes remember where they were opened from.
    func closeRecentlyDeleted() {
        goHome()
    }

    /// Enough to swallow a burst of keystrokes; the index itself answers well inside one.
    static let searchDebounce = Duration.milliseconds(70)

    func search(_ query: String) {
        let isNewQuery = query != searchQuery
        // A same-value write-back (e.g. a binding re-publishing) must not clear a failure that just landed.
        if isNewQuery { leaveFailedPhase() }
        searchTask?.cancel()
        // Only results can go stale on a new query; a list the transcript came from is still where it was.
        if isNewQuery, case .search = libraryOrigin { forgetLibraryOrigin() }
        searchQuery = query
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            searchRanking = nil
            searchMatches = [:]
            searchSnippetIDs = []
            searchResultsQuery = nil
            return
        }
        // Results land in the content area, so a query typed from Statistics or the trash has to leave the page.
        route = .transcript
        runSearch(q)
    }

    private func runSearch(_ q: String) {
        searchTask?.cancel()
        let clock = clock
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce, clock: clock)
            guard !Task.isCancelled, let self else { return }
            let matches = await library.search(q, snippetLimit: LibrarySearchResults.pageSize)
            guard !Task.isCancelled else { return }
            // Rows resolve against the published list; a hit it has yet to catch up with would drop out of the bridge's reply.
            if matches.contains(where: { libraryEntry(id: $0.entryID) == nil }) {
                await refreshLibraryAndWait()
                guard !Task.isCancelled else { return }
            }
            var published = matches
            var filled = Set(matches.prefix(LibrarySearchResults.pageSize).map(\.entryID))
            // The same query re-run after a library change keeps the snippets the list already asked for.
            if q == searchResultsQuery {
                let shown = searchSnippetIDs.subtracting(filled)
                let refill = matches.filter { shown.contains($0.entryID) }
                if !refill.isEmpty {
                    let refilled = await library.withSnippets(refill, query: q)
                    guard !Task.isCancelled else { return }
                    let byID = Dictionary(uniqueKeysWithValues: refilled.map { ($0.entryID, $0) })
                    published = matches.map { byID[$0.entryID] ?? $0 }
                    filled.formUnion(byID.keys)
                }
            }
            let askedMeanwhile = searchSnippetIDs.subtracting(filled)
            searchMatches = Dictionary(uniqueKeysWithValues: published.map { ($0.entryID, $0) })
            searchSnippetIDs = filled
            searchResultsQuery = q
            searchRanking = published.map(\.entryID)
            fillSearchSnippets(for: Array(askedMeanwhile))
        }
    }

    /// The results list asks as it shows a page: only the first one comes with its snippets.
    func fillSearchSnippets(for ids: [LibraryEntry.ID]) {
        let missing = ids.compactMap { id in searchSnippetIDs.contains(id) ? nil : searchMatches[id] }
        guard !missing.isEmpty else { return }
        searchSnippetIDs.formUnion(missing.map(\.entryID))
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        let results = searchResultsVersion
        Task { [weak self, library] in
            let filled = await library.withSnippets(missing, query: query)
            // A newer query or a re-run replaced the matches these were cut for.
            guard let self, searchResultsVersion == results else { return }
            var matches = searchMatches
            for match in filled where matches[match.entryID] != nil {
                matches[match.entryID] = match
            }
            searchMatches = matches
        }
    }

    /// A rename, a note or a card can change what the open query matches; re-ranks it where the page is.
    func refreshSearchResults() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard searchRanking != nil, !q.isEmpty else { return }
        runSearch(q)
    }

    func clearSearch() {
        search("")
    }

    func focusLibrarySearch() {
        librarySearchFocusRequests &+= 1
    }
}
