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
    @Published var promptOutput: PromptOutput?
    @Published var isRunningPrompt: Bool = false

    let promptLibrary = PromptLibrary()
    let peopleStore = PeopleStore()

    var searchTask: Task<Void, Never>?

    static let trashRetentionDays = 30

    struct PromptOutput: Identifiable {
        let id = UUID()
        let promptName: String
        let text: String
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
}
