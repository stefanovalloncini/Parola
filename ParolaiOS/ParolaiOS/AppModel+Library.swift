import Foundation
import SwiftUI
import ParolaCore

extension AppModel {
    /// RootView owns the selection, so the entry opens through the notification it listens for.
    func registerIntentPerformers() {
        IntentPerformers.openLatest = { [library] in
            let latest = try await IntentTranscriptLookup.latestTranscriptText(in: library, rescan: false)
            NotificationCenter.default.post(name: .parolaOpenEntry, object: nil, userInfo: ["id": latest.entryID])
            return latest.text
        }
    }

    func refreshLibrary() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let active = await library.list()
            let deleted = await library.listDeleted()
            guard !Task.isCancelled else { return }
            self.libraryEntries = active
            self.deletedEntries = deleted
        }
    }

    /// Picks up what another process saved into the library while the app was in the background.
    func refreshLibraryIfChangedElsewhere() {
        Task { [weak self, library] in
            guard await library.folderChangedElsewhere() else { return }
            await library.dropCaches()
            self?.refreshLibrary()
        }
    }

    func deleteEntry(_ id: LibraryEntry.ID) {
        Task {
            do {
                try await library.delete(id)
            } catch {
                lastError = FailureText.message(for: error)
            }
            refreshLibrary()
        }
    }

    func restoreEntry(_ id: LibraryEntry.ID) {
        Task {
            do {
                try await library.restore(id)
            } catch {
                lastError = FailureText.message(for: error)
            }
            refreshLibrary()
        }
    }

    func purgeEntry(_ id: LibraryEntry.ID) {
        Task {
            do {
                try await library.purge(id)
            } catch {
                lastError = FailureText.message(for: error)
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
            let matches = await library.search(q, snippetLimit: 0)
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
