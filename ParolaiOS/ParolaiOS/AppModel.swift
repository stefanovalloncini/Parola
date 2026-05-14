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
    @Published var lastError: String?

    init(libraryURL: URL = LibraryStore.defaultLibraryURL) {
        let store = LibraryStore(libraryURL: libraryURL)
        self.library = store
        let userSettings = UserSettings()
        self.settings = userSettings
        self.coordinator = TranscriptionCoordinator(library: store, settings: userSettings)
        coordinator.onComplete = { [weak self] _ in
            self?.refreshLibrary()
        }
        refreshModelList()
        refreshLibrary()
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
        Task { [weak self] in
            guard let self else { return }
            let entries = await self.library.list()
            await MainActor.run { self.libraryEntries = entries }
        }
    }

    func deleteEntry(_ id: LibraryEntry.ID) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.library.delete(id)
            self.refreshLibrary()
        }
    }
}
