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
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .titleAZ: return "Title A→Z"
        case .titleZA: return "Title Z→A"
        case .longest: return "Largest first"
        case .shortest: return "Smallest first"
        case .lastOpened: return "Last opened"
        }
    }
}

/// The list a transcript was opened from, so the sidebar keeps its row and the header can offer the way back.
enum LibraryOrigin: Equatable {
    case home
    case all
    case category(EntryCategory)
    case search

    /// Read through the sidebar's own selection, so a search wins over the category filter underneath it.
    static func capture(sidebar: SidebarRoute, homeOnScreen: Bool) -> LibraryOrigin? {
        switch sidebar {
        case .search: return .search
        case .all: return .all
        case .category(let category): return .category(category)
        case .home: return homeOnScreen ? .home : nil
        case .queue, .batch, .statistics, .recentlyDeleted: return nil
        }
    }

    /// The source key, not a `LocalizedStringKey`, so the back link can both show the name and say "Back to <name>".
    var name: String {
        switch self {
        case .home: return "Home"
        case .all: return "All"
        case .category(let category): return libraryCategoryName(category)
        case .search: return "Results"
        }
    }

    var bridgeName: String {
        switch self {
        case .home: return "home"
        case .all: return "all"
        case .category(let category): return category.rawValue
        case .search: return "search"
        }
    }
}

extension AppModel {

    func refreshLibrary() {
        libraryRefreshTask?.cancel()
        libraryRefreshTask = Task { [weak self] in
            guard let self else { return }
            let active = await library.list()
            let deleted = await library.listDeleted()
            // A later refreshLibrary() cancels this one; its snapshot may predate a mutation, so don't let it overwrite the newer result.
            if Task.isCancelled { return }
            setDeletedEntries(deleted)
            refreshBundleSizes(for: active)
            setLibraryEntries(sortedLibraryEntries(active))
            refreshLibraryExcerpts()
        }
    }

    /// Rows quote a transcript's first lines; the index is the only place that text is already in memory.
    func refreshLibraryExcerpts() {
        libraryExcerptsTask?.cancel()
        // The store compares against what is already on screen, so the main actor never walks the map.
        let known = libraryExcerpts
        libraryExcerptsTask = Task { [weak self] in
            guard let self else { return }
            guard let excerpts = await library.excerpts(changedFrom: known) else { return }
            guard !Task.isCancelled else { return }
            libraryExcerpts = excerpts
        }
    }

    /// A refresh runs on every library touch, most of which change nothing, and reassigning anyway repaints every reader.
    func setLibraryEntries(_ entries: [LibraryEntry]) {
        guard !Self.sameEntries(entries, libraryEntries, comparingLastOpened: librarySortOrder == .lastOpened) else { return }
        libraryEntries = entries
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
            .map { (title: LibraryEntryDisplay.title(for: $0), entry: $0) }
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
            return entries.sorted { (libraryBundleSizes[$0.id] ?? 0) > (libraryBundleSizes[$1.id] ?? 0) }
        case .shortest:
            return entries.sorted { (libraryBundleSizes[$0.id] ?? 0) < (libraryBundleSizes[$1.id] ?? 0) }
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
            if self.librarySortOrder == .longest || self.librarySortOrder == .shortest {
                self.reapplyLibrarySort()
            }
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

    func setLabels(_ labels: [String], for id: LibraryEntry.ID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.setLabels(labels, for: id)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            refreshLibrary()
        }
    }

    func moveEntry(_ id: LibraryEntry.ID, to category: EntryCategory) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.setCategory(category, for: id)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            refreshLibrary()
        }
    }

    func togglePinned(for id: LibraryEntry.ID) {
        let current = libraryEntry(id: id)?.pinned ?? false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.setPinned(!current, for: id)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            refreshLibrary()
        }
    }

    func renameEntry(_ id: LibraryEntry.ID, to newName: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.renameEntry(id, to: newName)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            refreshLibrary()
        }
    }

    func setSegmentNote(_ note: String?, segmentID: Int) {
        guard let entryID = selectedEntryID else { return }
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

    func currentSegmentNote(for segmentID: Int) -> String? {
        guard let id = selectedEntryID, let entry = libraryEntry(id: id) else { return nil }
        return entry.note(forSegment: segmentID)
    }

    func deleteEntry(_ id: LibraryEntry.ID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.delete(id)
                if selectedEntryID == id { clearLoadedEntry() }
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            refreshLibrary()
        }
    }

    func restoreEntry(_ id: LibraryEntry.ID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.restore(id)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            refreshLibrary()
        }
    }

    func purgeEntry(_ id: LibraryEntry.ID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.purge(id)
                if selectedEntryID == id { clearLoadedEntry() }
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            refreshLibrary()
        }
    }

    func clearLoadedEntry() {
        pendingTranscriptSaveTask?.cancel()
        pendingTranscriptSaveTask = nil
        clearDerivedArtifacts()
        selectedEntryID = nil
        transcript = nil
        sourceFileURL = nil
        tearDownPlayer()
        if case .ready = phase { phase = .idle }
    }

    func bulkExportEntries(ids: Set<LibraryEntry.ID>, format: ExportFormat) {
        guard !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let entriesByID = Dictionary(uniqueKeysWithValues: libraryEntries.map { ($0.id, $0) })
        let targets = ids.compactMap { entriesByID[$0] }
        let exporter = makeExporter(for: format)
        Task { [library, weak self] in
            var usedNames = Set<String>()
            for entry in targets {
                do {
                    let loaded = try await library.load(entry.id)
                    let transcript = loaded.document.transcript
                    let safe = TranscriptShareFile.safeName(for: LibraryEntryDisplay.title(for: entry))
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
                    }
                } catch {
                    // An entry id is <timestamp>-<uuid>; only the uuid half is loggable.
                    var fields: [LogField: LogValue] = [.error: .error(error)]
                    if let uuid = UUID(uuidString: String(entry.id.suffix(36))) {
                        fields[.entry] = .id(uuid)
                    }
                    ParolaLog.error(.export, "library export failed as \(format)", fields)
                    await MainActor.run { [weak self] in
                        let name = LibraryEntryDisplay.title(for: entry)
                        let reason = error.localizedDescription
                        self?.phase = .failed(
                            message: String(localized: "Export of \(name) failed: \(reason)")
                        )
                    }
                    return
                }
            }
        }
    }

    func loadEntry(_ id: LibraryEntry.ID) {
        introduction.defer()
        loadEntryGeneration &+= 1
        let generation = loadEntryGeneration
        // Read before the transcript takes the content area, which is what hides the list it came from.
        let origin = captureLibraryOrigin()
        let hit = searchResults == nil ? nil : searchQuery.trimmingCharacters(in: .whitespaces)
        let hitPosition = searchMatches[id]?.firstHit
        Task { [weak self] in
            guard let self else { return }
            await flushPendingTranscriptSave()
            do {
                let loaded = try await library.load(id)
                // Two quick clicks race across the await, and the slower load would land last.
                guard generation == loadEntryGeneration else { return }
                installStoredTranscript(loaded.document.transcript)
                closeFind()
                sourceFileURL = loaded.document.audioURL
                selectedEntryID = id
                if let audioURL = loaded.document.audioURL {
                    installPlayer(for: audioURL)
                    adoptLoadedMediaDuration()
                } else {
                    tearDownPlayer()
                }
                phase = .ready
                // Opened from the extra, a link or the duplicate sheet, it would otherwise load behind a page.
                route = .transcript
                libraryOrigin = origin
                libraryOriginEntryID = id
                if let hit, !hit.isEmpty { revealInTranscript(hit, at: hitPosition) }
                let openedAt = Date()
                if (try? await library.markOpened(id: id, at: openedAt)) != nil {
                    patchLibraryEntry(id: id) { $0.lastOpenedAt = openedAt }
                }
                refreshLibrary()
            } catch {
                guard generation == loadEntryGeneration else { return }
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Sidebar Home: the launcher only renders with nothing loaded, so the transcript has to go.
    func goHome() {
        libraryFilter = nil
        libraryBrowsingAll = false
        showList()
    }

    func browseAll() {
        libraryFilter = nil
        libraryBrowsingAll = true
        showList()
    }

    func browseCategory(_ category: EntryCategory) {
        libraryFilter = category
        libraryBrowsingAll = false
        showList()
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

    /// The transcript header's back link: leaves the list the entry was opened from exactly as it was.
    func returnToOrigin() {
        switch transcriptOrigin {
        case .category(let category):
            libraryFilter = category
            libraryBrowsingAll = false
        case .all:
            libraryFilter = nil
            libraryBrowsingAll = true
        case .search:
            break
        case .home, nil:
            libraryFilter = nil
            libraryBrowsingAll = false
            clearSearch()
        }
        forgetLibraryOrigin()
        route = .transcript
        closeTranscript()
    }

    /// Nil when no list is behind the transcript: a root page, a batch, or Home with something already loaded.
    func captureLibraryOrigin() -> LibraryOrigin? {
        LibraryOrigin.capture(
            sidebar: SidebarRoute.selected(
                route: route,
                searching: searchResults != nil,
                filter: libraryFilter,
                browsingAll: libraryBrowsingAll
            ),
            homeOnScreen: batchJobs.isEmpty && !hasTranscript
        )
    }

    /// Flush first, so a debounced edit from the last second still reaches the library.
    func closeTranscript() {
        guard case .ready = phase, transcript != nil else { return }
        Task { [weak self] in
            await self?.flushPendingTranscriptSave()
            self?.clearLoadedEntry()
        }
    }

    func openStatistics() {
        openPage(.statistics, keepingTranscript: false)
    }

    func openRecentlyDeleted() {
        openPage(.recentlyDeleted, keepingTranscript: false)
    }

    /// A batch writes `route` itself while one is running, so stepping in from the sidebar leaves what is loaded alone.
    func openQueue() {
        openPage(.queue, keepingTranscript: true)
    }

    func openBatch() {
        openPage(.batch, keepingTranscript: true)
    }

    private func openPage(_ page: Route, keepingTranscript: Bool) {
        leaveList(keepingTranscript: keepingTranscript)
        libraryFilter = nil
        libraryBrowsingAll = false
        route = page
    }

    /// Home is the stand-in destination until routes remember where they were opened from.
    func closeRecentlyDeleted() {
        goHome()
    }

    /// Enough to swallow a burst of keystrokes; the index itself answers well inside one.
    static let searchDebounce = Duration.milliseconds(70)

    func search(_ query: String) {
        searchTask?.cancel()
        // Only results can go stale on a new query; a list the transcript came from is still where it was.
        if query != searchQuery, case .search = libraryOrigin { forgetLibraryOrigin() }
        searchQuery = query
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            searchResults = nil
            searchMatches = [:]
            return
        }
        // Results land in the content area, so a query typed from Statistics or the trash has to leave the page.
        route = .transcript
        let clock = clock
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce, clock: clock)
            guard !Task.isCancelled, let self else { return }
            let matches = await library.search(q)
            guard !Task.isCancelled else { return }
            let matchByID = Dictionary(uniqueKeysWithValues: matches.map { ($0.entryID, $0) })
            let active = await library.list()
            guard !Task.isCancelled else { return }
            searchMatches = matchByID
            searchResults = active
                .filter { matchByID[$0.id] != nil }
                .sorted { (matchByID[$0.id]?.score ?? 0) > (matchByID[$1.id]?.score ?? 0) }
        }
    }

    func clearSearch() {
        search("")
    }
}
