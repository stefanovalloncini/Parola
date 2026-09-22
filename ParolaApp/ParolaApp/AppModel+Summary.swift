import Foundation
import ParolaCore

extension AppModel {
    func summariseTranscript(options: SummaryOptions? = nil) {
        guard features.isEnabled(.ai) else { return }
        guard let transcript, !isSummarising else { return }
        let resolvedOptions = options ?? summaryOptions
        isSummarising = true
        summaryError = nil
        summaryGeneration &+= 1
        let generation = summaryGeneration
        let snapshot = transcript
        let entryID = selectedEntryID
        let artifacts = derivedArtifactsGeneration
        let makeModel = summaryModelMaker()
        let provider = languageModelLabel(for: .summary)
        let summarise = summariseOperation ?? { [features] transcript, options in
            guard let makeModel else {
                return try await SummaryService(features: features).summarise(transcript, options: options)
            }
            return try await SummaryService(features: features, makeModel: makeModel)
                .summarise(transcript, options: options)
        }
        Task { [weak self] in
            do {
                var summary = try await summarise(snapshot, resolvedOptions)
                summary.provider = provider
                guard let self, generation == summaryGeneration else { return }
                // A nil entry id means the transcript wasn't in the library yet: persistToLibrary
                // selects it moments later, and that late selection owns this summary.
                guard self.derivedArtifactsGeneration == artifacts,
                      entryID == nil || self.selectedEntryID == entryID else { isSummarising = false; return }
                self.transcript?.summary = summary
                isSummarising = false
                if let entryID = self.selectedEntryID, let updated = self.transcript {
                    Task { [library] in
                        try? await library.updateTranscript(updated, for: entryID, reindex: false)
                    }
                }
            } catch {
                guard let self, generation == summaryGeneration else { return }
                summaryError = error.localizedDescription
                isSummarising = false
                refreshAIAvailability()
            }
        }
    }

    func clearSummary() {
        guard transcript?.summary != nil else { return }
        transcript?.summary = nil
        summaryError = nil
        if let entryID = selectedEntryID, let updated = transcript {
            Task { [library] in
                try? await library.updateTranscript(updated, for: entryID, reindex: false)
            }
        }
    }

    // MARK: - Transcript pane mode

    enum TranscriptPaneMode: String, CaseIterable, Sendable {
        case transcript, summary, chat
    }

    /// Every mode needs a transcript; `.summary`/`.chat` also need the AI feature.
    func canShow(_ mode: TranscriptPaneMode) -> Bool {
        switch mode {
        case .transcript: return transcript != nil
        case .summary, .chat: return transcript != nil && features.isEnabled(.ai)
        }
    }

    /// The one entry point for switching modes: the picker, the AI menu, ⌘1/2/3 and the bridge all call this.
    func setTranscriptPaneMode(_ mode: TranscriptPaneMode) {
        guard canShow(mode) else { return }
        transcriptPaneMode = mode
    }
}
