import Foundation
import ParolaCore

extension AppModel {
    var translationState: TranslationState {
        translationCoordinator.state(for: selectedEntryID)
    }

    var canTranslateTranscript: Bool {
        transcript != nil && selectedEntryID != nil && !translationCoordinator.isRunning
    }

    /// How a translation request ended, so a caller reports this run and not whatever state the coordinator holds.
    enum TranslationRunResult: Equatable {
        case landed(cancelled: Bool, translation: TranscriptTranslation)
        case refused(String)
        case cancelled
        case failed(String)

        /// Whether the run landed, and if so whether it was cut short; nil when it landed nothing.
        var landedCancelled: Bool? {
            if case .landed(let cancelled, _) = self { return cancelled }
            return nil
        }
    }

    /// The one entry point for translating the open transcript: the inspector menu, the View menu
    /// and the bridge all call this.
    @discardableResult
    func translateTranscript(to language: String) async -> TranslationRunResult {
        if translationCoordinator.isRunning { return .refused("another translation is already running") }
        guard let transcript, let entryID = selectedEntryID else {
            return .refused(selectedEntryID == nil ? "the transcript is not a library entry" : "no transcript is open")
        }
        let target = language.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return .refused("the language is empty") }
        let hadTranslation = transcript.translation != nil
        guard let outcome = await translationCoordinator.translate(
            entryID: entryID, transcript: transcript, to: target
        ) else {
            if translationCoordinator.cancelRequested { return .cancelled }
            if case .failed(let message) = translationCoordinator.state { return .failed(message) }
            return .refused("the transcript has no text to translate")
        }
        // A cancelled or failed re-translation would swap a whole translation for a partial one.
        if hadTranslation {
            if outcome.cancelled { return .cancelled }
            if outcome.failed, case .failed(let message) = translationCoordinator.state { return .failed(message) }
        }
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
        return .landed(cancelled: outcome.cancelled, translation: translation)
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

    /// Lets go of a failed run's note; a translation the entry already had stays.
    func dismissTranslationFailure() {
        guard let entryID = selectedEntryID, case .failed = translationState else { return }
        translationCoordinator.remove(entryID: entryID)
    }

    private func persistTranslation(_ translation: TranscriptTranslation?, for entryID: LibraryEntry.ID) async {
        do {
            try await library.setTranslation(translation, for: entryID)
        } catch {
            ParolaLog.error(.library, "translation could not be saved to the library", [.error: .error(error)])
            nonFatalWarning = String(localized: "The translation is still on screen, but Parola couldn't save it to your library. \(FailureText.message(for: error))")
        }
    }
}
