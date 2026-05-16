import Foundation
import SwiftUI
import ParolaCore

@MainActor
final class AppModel: ObservableObject {
    let library: LibraryStore
    @Published var settings: UserSettings
    let coordinator: TranscriptionCoordinator
    let playback = PlaybackController()

    @Published var availableModels: [ModelInfo] = []
    @Published var libraryEntries: [LibraryEntry] = []
    @Published var deletedEntries: [LibraryEntry] = []
    @Published var searchResults: [LibraryEntry]?
    @Published var autoExportRules: [AutoExportRule] = [] {
        didSet { saveAutoExportRules() }
    }
    @Published var ignoredSegmentRules: [IgnoredSegmentRule] = [] {
        didSet { saveIgnoredSegmentRules() }
    }
    @Published var findReplaceRules: [FindReplaceRule] = [] {
        didSet { saveFindReplaceRules() }
    }
    @Published var lastError: String?

    private var searchTask: Task<Void, Never>?

    static let trashRetentionDays = 30

    private func loadAutoExportRules() {
        guard let data = UserDefaults.standard.data(forKey: "autoExportRules"),
              let rules = try? JSONDecoder().decode([AutoExportRule].self, from: data) else { return }
        autoExportRules = rules
    }

    private func saveAutoExportRules() {
        if let data = try? JSONEncoder().encode(autoExportRules) {
            UserDefaults.standard.set(data, forKey: "autoExportRules")
        }
    }

    private func loadIgnoredSegmentRules() {
        guard let data = UserDefaults.standard.data(forKey: "ignoredSegmentRules"),
              let rules = try? JSONDecoder().decode([IgnoredSegmentRule].self, from: data) else { return }
        ignoredSegmentRules = rules
    }

    private func saveIgnoredSegmentRules() {
        if let data = try? JSONEncoder().encode(ignoredSegmentRules) {
            UserDefaults.standard.set(data, forKey: "ignoredSegmentRules")
        }
    }

    private func loadFindReplaceRules() {
        guard let data = UserDefaults.standard.data(forKey: "findReplaceRules"),
              let rules = try? JSONDecoder().decode([FindReplaceRule].self, from: data) else { return }
        findReplaceRules = rules
    }

    private func saveFindReplaceRules() {
        if let data = try? JSONEncoder().encode(findReplaceRules) {
            UserDefaults.standard.set(data, forKey: "findReplaceRules")
        }
    }

    private func runAutoExports(for entry: LibraryEntry) {
        let ext = (entry.manifest.originalAudioName as NSString).pathExtension
        let formats = AutoExportEngine.plannedFormats(rules: autoExportRules, sourceExtension: ext)
        guard !formats.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await library.load(entry.id)
                let exportsDir = library.libraryURL.appendingPathComponent("Exports", isDirectory: true)
                try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
                let base = (entry.title as NSString).deletingPathExtension
                for format in formats {
                    let target = exportsDir.appendingPathComponent("\(base).\(format.fileExtension)")
                    let data = try Exporters.exporter(for: format).render(loaded.document.transcript)
                    try data.write(to: target, options: .atomic)
                }
            } catch {
                // Best-effort; primary transcription already saved.
            }
        }
    }

    init(libraryURL: URL = LibraryStore.defaultLibraryURL) {
        let store = LibraryStore(libraryURL: libraryURL)
        self.library = store
        let userSettings = UserSettings()
        self.settings = userSettings
        self.coordinator = TranscriptionCoordinator(library: store, settings: userSettings)
        coordinator.onComplete = { [weak self] entry in
            self?.refreshLibrary()
            self?.runAutoExports(for: entry)
        }
        loadAutoExportRules()
        loadIgnoredSegmentRules()
        loadFindReplaceRules()
        coordinator.postProcessor = { [weak self] transcript in
            guard let self else { return transcript }
            var out = transcript
            out.segments = IgnoredSegments.apply(rules: self.ignoredSegmentRules, to: out.segments)
            out.segments = GlobalFindReplace.apply(rules: self.findReplaceRules, to: out.segments)
            return out
        }
        refreshModelList()
        refreshLibrary()
        Task { [weak self] in
            await store.purgeDeletedOlderThan(days: AppModel.trashRetentionDays, now: Date())
            self?.refreshLibrary()
        }
    }

    func refreshModelList() {
        availableModels = ModelStore.shared.catalog()
        if !availableModels.contains(where: { $0.name == settings.modelName }) {
            settings.modelName = availableModels.first?.name ?? "openai_whisper-tiny"
        }
    }

    func deleteModel(_ name: String) {
        try? ModelStore.shared.delete(variant: name)
        refreshModelList()
    }

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

extension AppModel {
    func handleIncoming(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            if url.pathExtension.lowercased() == "parola" {
                _ = try await library.adopt(parolaBundle: url)
                refreshLibrary()
            } else {
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("parola-incoming-\(UUID().uuidString)-\(url.lastPathComponent)")
                try await FileCopier.copy(from: url, to: copy)
                coordinator.startFileTranscriptionFromTrustedCopy(at: copy)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}

enum FileCopier {
    static func copy(from source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
    }
}
