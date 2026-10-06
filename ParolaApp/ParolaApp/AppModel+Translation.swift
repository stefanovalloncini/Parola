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
        let translation = TranscriptTranslation(
            targetLanguage: target,
            segments: outcome.segments,
            createdAt: Date(),
            provider: outcome.provider
        )
        // The write is addressed to the entry that asked for it, so a run that finishes after the
        // user moved on still lands; only the transcript on screen is left alone.
        if selectedEntryID == entryID { self.transcript?.translation = translation }
        await persistTranslation(translation, for: entryID)
    }

    /// The one entry point for dropping a translation.
    func removeTranslation() async {
        guard let entryID = selectedEntryID, let removed = transcript?.translation else { return }
        translationCoordinator.remove(entryID: entryID)
        transcript?.translation = nil
        registerTranslationUndo(String(localized: "Remove Translation"), restoring: removed, for: entryID)
        await persistTranslation(nil, for: entryID)
    }

    private func registerTranslationUndo(_ actionName: String, restoring old: TranscriptTranslation?, for entryID: LibraryEntry.ID) {
        registerUndoStep(actionName: actionName) { model in
            guard model.selectedEntryID == entryID, model.transcript != nil else { return }
            let current = model.transcript?.translation
            model.transcript?.translation = old
            model.registerTranslationUndo(actionName, restoring: current, for: entryID)
            Task { await model.persistTranslation(old, for: entryID) }
        }
    }

    func cancelTranslation() {
        translationCoordinator.cancel()
    }

    private func persistTranslation(_ translation: TranscriptTranslation?, for entryID: LibraryEntry.ID) async {
        do {
            try await library.setTranslation(translation, for: entryID)
        } catch {
            ParolaLog.error(.library, "translation could not be saved to the library", [.error: .error(error)])
            nonFatalWarning = String(localized: "The translation is still on screen, but Parola couldn't save it to your library. \(error.localizedDescription)")
        }
    }
}
