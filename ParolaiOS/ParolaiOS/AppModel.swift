import Foundation
import ParolaCore

@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let library: LibraryStore
    let settings: UserSettings
    @ObservationIgnored let coordinator: TranscriptionCoordinator
    let playback = PlaybackController()

    var availableModels: [ModelInfo] = []
    var libraryEntries: [LibraryEntry] = []
    var deletedEntries: [LibraryEntry] = []
    var searchResults: [LibraryEntry]?
    var autoExportRules: [AutoExportRule] = [] {
        didSet { saveAutoExportRules() }
    }
    var ignoredSegmentRules: [IgnoredSegmentRule] = [] {
        didSet { saveIgnoredSegmentRules() }
    }
    var findReplaceRules: [FindReplaceRule] = [] {
        didSet { saveFindReplaceRules() }
    }
    var lastError: String?
    var promptOutput: PromptOutput?
    var isRunningPrompt: Bool = false

    @ObservationIgnored let promptLibrary = PromptLibrary()
    @ObservationIgnored let peopleStore = PeopleStore()

    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?

    static let trashRetentionDays = 30

    nonisolated static func modelLabel(_ id: String) -> String {
        ModelCatalog.variant(id: id)?.displayName ?? id
    }

    struct PromptOutput: Identifiable {
        let id = UUID()
        let promptName: String
        let text: String
    }

    init(libraryURL: URL = LibraryStore.defaultLibraryURL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let store = LibraryStore(libraryURL: libraryURL)
        self.library = store
        let userSettings = UserSettings(defaults: defaults)
        self.settings = userSettings
        self.coordinator = TranscriptionCoordinator(library: store, settings: userSettings)
        coordinator.onComplete = { [weak self] entry in
            self?.refreshLibrary()
            self?.runAutoExports(for: entry)
        }
        loadAutoExportRules()
        loadIgnoredSegmentRules()
        loadFindReplaceRules()
        coordinator.postProcessor = { [weak self] in
            TranscriptPostProcessor(
                ignoredRules: self?.ignoredSegmentRules ?? [],
                findReplaceRules: self?.findReplaceRules ?? []
            )
        }
        refreshModelList()
        Task { await store.warmSearchIndex() }
        refreshLibrary()
        Task { [weak self] in
            let purge = await store.purgeDeletedOlderThan(days: AppModel.trashRetentionDays, now: Date())
            guard purge.purged > 0 || purge.failed > 0 else { return }
            self?.refreshLibrary()
        }
    }
}
