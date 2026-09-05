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
        }
    }

    /// A refresh runs on every library touch, most of which change nothing, and reassigning anyway repaints every reader.
    func setLibraryEntries(_ entries: [LibraryEntry]) {
        guard !Self.sameEntries(entries, libraryEntries) else { return }
        libraryEntries = entries
    }

    func setDeletedEntries(_ entries: [LibraryEntry]) {
        guard !Self.sameEntries(entries, deletedEntries) else { return }
        deletedEntries = entries
    }

    /// LibraryEntry equality is id-only, so a rename or a pin would slip through without comparing manifests.
    static func sameEntries(_ lhs: [LibraryEntry], _ rhs: [LibraryEntry]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.id == $1.id && $0.manifest == $1.manifest }
    }

    func reapplyLibrarySort() {
        libraryEntries = sortedLibraryEntries(libraryEntries)
    }

    func sortedLibraryEntries(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        switch librarySortOrder {
        case .newest:
            return entries.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return entries.sorted { $0.createdAt < $1.createdAt }
        case .titleAZ:
            return entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleZA:
            return entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
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
                    let safe = entry.title.replacingOccurrences(of: "/", with: "-")
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
                    await MainActor.run { [weak self] in
                        self?.phase = .failed(message: "Export of \(entry.title) failed: \(error.localizedDescription)")
                    }
                    return
                }
            }
        }
    }

    func loadEntry(_ id: LibraryEntry.ID) {
        loadEntryGeneration &+= 1
        let generation = loadEntryGeneration
        Task { [weak self] in
            guard let self else { return }
            await flushPendingTranscriptSave()
            do {
                let loaded = try await library.load(id)
                // Two quick clicks race across the load await; the slower load would otherwise
                // finish last and install the entry the user already navigated away from.
                guard generation == loadEntryGeneration else { return }
                clearDerivedArtifacts()
                transcript = loaded.document.transcript
                adoptSavedChapters()
                sourceFileURL = loaded.document.audioURL
                selectedEntryID = id
                if let audioURL = loaded.document.audioURL {
                    installPlayer(for: audioURL)
                    adoptLoadedMediaDuration()
                } else {
                    tearDownPlayer()
                }
                phase = .ready
                libraryFilter = nil
                libraryBrowsingAll = false
                searchResults = nil
                try? await library.markOpened(id: id)
                refreshLibrary()
            } catch {
                guard generation == loadEntryGeneration else { return }
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Sidebar Home. The launcher only renders with nothing loaded, so a transcript left in
    /// place would keep showing under a selected Home row; flush first so a debounced edit
    /// from the last second still reaches the library.
    func goHome() {
        libraryFilter = nil
        libraryBrowsingAll = false
        route = .transcript
        guard case .ready = phase, transcript != nil else { return }
        Task { [weak self] in
            await self?.flushPendingTranscriptSave()
            self?.clearLoadedEntry()
        }
    }

    func search(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            searchResults = nil
            return
        }
        let clock = clock
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200), clock: clock)
            guard !Task.isCancelled, let self else { return }
            let matches = await library.search(q)
            guard !Task.isCancelled else { return }
            let scoreByID = Dictionary(uniqueKeysWithValues: matches.map { ($0.entryID, $0.score) })
            let active = await library.list()
            guard !Task.isCancelled else { return }
            searchResults = active
                .filter { scoreByID[$0.id] != nil }
                .sorted { (scoreByID[$0.id] ?? 0) > (scoreByID[$1.id] ?? 0) }
        }
    }
}
