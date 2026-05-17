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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .titleAZ: return "Title A→Z"
        case .titleZA: return "Title Z→A"
        case .longest: return "Longest first"
        case .shortest: return "Shortest first"
        }
    }
}

extension AppModel {

    func refreshLibrary() {
        Task { [weak self] in
            guard let self else { return }
            let active = await library.list()
            deletedEntries = await library.listDeleted()
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
        }
    }

    private func refreshBundleSizes(for entries: [LibraryEntry]) {
        let fm = FileManager.default
        var sizes: [String: Int64] = [:]
        for entry in entries {
            let contents = (try? fm.contentsOfDirectory(at: entry.bundleURL, includingPropertiesForKeys: nil)) ?? []
            let audio = contents.first(where: { $0.lastPathComponent.hasPrefix("audio.") })
            if let audio,
               let values = try? audio.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                sizes[entry.id] = Int64(size)
            } else {
                sizes[entry.id] = 0
            }
        }
        libraryBundleSizes = sizes
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

    private func clearLoadedEntry() {
        selectedEntryID = nil
        transcript = nil
        sourceFileURL = nil
        tearDownPlayer()
        if case .ready = phase { phase = .idle }
    }

    func loadEntry(_ id: LibraryEntry.ID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await library.load(id)
                transcript = loaded.document.transcript
                sourceFileURL = loaded.document.audioURL
                if let audioURL = loaded.document.audioURL {
                    installPlayer(for: audioURL)
                } else {
                    tearDownPlayer()
                }
                phase = .ready
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
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
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
