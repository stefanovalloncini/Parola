import Foundation
import SwiftUI
import ParolaCore

extension AppModel {
    func refreshLibrary() {
        Task {
            libraryEntries = await library.list()
            deletedEntries = await library.listDeleted()
        }
    }

    func deleteEntry(_ id: LibraryEntry.ID) {
        Task {
            do {
                try await library.delete(id)
            } catch {
                lastError = error.localizedDescription
            }
            refreshLibrary()
        }
    }

    func restoreEntry(_ id: LibraryEntry.ID) {
        Task {
            do {
                try await library.restore(id)
            } catch {
                lastError = error.localizedDescription
            }
            refreshLibrary()
        }
    }

    func purgeEntry(_ id: LibraryEntry.ID) {
        Task {
            do {
                try await library.purge(id)
            } catch {
                lastError = error.localizedDescription
            }
            refreshLibrary()
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
            let filtered = active
                .filter { scoreByID[$0.id] != nil }
                .sorted { (scoreByID[$0.id] ?? 0) > (scoreByID[$1.id] ?? 0) }
            searchResults = filtered
        }
    }
}
