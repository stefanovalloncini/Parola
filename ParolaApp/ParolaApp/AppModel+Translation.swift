import Foundation
import ParolaCore

extension AppModel {
    var translationState: TranslationState {
        translationCoordinator.state(for: selectedEntryID)
    }

    var canTranslateTranscript: Bool {
        transcript != nil && selectedEntryID != nil && !translationCoordinator.isRunning
    }

    /// The one entry point for translating the open transcript: the inspector menu, the View menu
    /// and the bridge all call this.
    func translateTranscript(to language: String) async {
        guard canTranslateTranscript, let transcript, let entryID = selectedEntryID else { return }
        let target = language.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return }
        guard let outcome = await translationCoordinator.translate(
            entryID: entryID, transcript: transcript, to: target
        ) else { return }
        guard selectedEntryID == entryID else { return }
        let translation = TranscriptTranslation(
            targetLanguage: target,
            segments: outcome.segments,
            createdAt: Date(),
            provider: outcome.provider
        )
        self.transcript?.translation = translation
        await persistTranslation(translation, for: entryID)
    }

    /// The one entry point for dropping a translation.
    func removeTranslation() async {
        guard let entryID = selectedEntryID, transcript?.translation != nil else { return }
        translationCoordinator.remove(entryID: entryID)
        transcript?.translation = nil
        await persistTranslation(nil, for: entryID)
    }

    func cancelTranslation() {
        translationCoordinator.cancel()
    }

    private func persistTranslation(_ translation: TranscriptTranslation?, for entryID: LibraryEntry.ID) async {
        do {
            try await library.setTranslation(translation, for: entryID)
        } catch {
            ParolaLog.error(.library, "translation could not be saved to the library", [.error: .error(error)])
            nonFatalWarning = "The translation is still on screen, but Parola couldn't save it to your library. \(error.localizedDescription)"
        }
    }
}
