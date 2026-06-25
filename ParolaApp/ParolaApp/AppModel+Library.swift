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
            deletedEntries = deleted
            refreshBundleSizes(for: active)
            libraryEntries = sortedLibraryEntries(active)
        }
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
        let bundles = entries.map { (id: $0.id, url: $0.bundleURL) }
        Task.detached(priority: .utility) { [weak self] in
            let fm = FileManager.default
            var sizes: [String: Int64] = [:]
            for bundle in bundles {
                let contents = (try? fm.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil)) ?? []
                let audio = contents.first(where: { $0.lastPathComponent.hasPrefix("audio.") })
                if let audio,
                   let values = try? audio.resourceValues(forKeys: [.fileSizeKey]),
                   let size = values.fileSize {
                    sizes[bundle.id] = Int64(size)
                } else {
                    sizes[bundle.id] = 0
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.libraryBundleSizes = sizes
                if self.librarySortOrder == .longest || self.librarySortOrder == .shortest {
                    self.reapplyLibrarySort()
                }
            }
        }
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

    var allKnownLabels: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in libraryEntries {
            for label in entry.labels {
                if seen.insert(label).inserted { ordered.append(label) }
            }
        }
        return ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
                    let data = try exporter.render(loaded.document.transcript)
                    let safe = entry.title.replacingOccurrences(of: "/", with: "-")
                    var name = safe
                    var suffix = 2
                    while usedNames.contains(name) {
                        name = "\(safe) (\(suffix))"
                        suffix += 1
                    }
                    usedNames.insert(name)
                    let url = folder.appendingPathComponent("\(name).\(format.fileExtension)")
                    try data.write(to: url, options: .atomic)
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await library.load(id)
                transcript = loaded.document.transcript
                sourceFileURL = loaded.document.audioURL
                selectedEntryID = id
                if let audioURL = loaded.document.audioURL {
                    installPlayer(for: audioURL)
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
                phase = .failed(message: error.localizedDescription)
            }
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
