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
                self.transcript?.install(summary: summary)
                adoptSavedChapters()
                isSummarising = false
                if let entryID = self.selectedEntryID {
                    Task { [library] in
                        try? await library.setSummary(summary, for: entryID)
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

    /// The bridge's write path for the saved options, so it goes through a seam like its four
    /// JSON-backed siblings; the options column binds to the property directly.
    func setSummaryOptions(_ options: SummaryOptions) {
        guard options != summaryOptions else { return }
        summaryOptions = options
    }

    func clearSummary() {
        guard transcript?.summary != nil else { return }
        transcript?.removeSummary()
        adoptSavedChapters()
        summaryError = nil
        if let entryID = selectedEntryID {
            Task { [library] in
                try? await library.setSummary(nil, for: entryID)
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

extension Transcript {
    /// One chapter list from the moment a summary lands: the summary's own chapters, or the ones already kept when it brought none.
    mutating func install(summary: Summary) {
        var summary = summary
        if summary.chapters.isEmpty {
            summary.chapters = chapters ?? self.summary?.chapters ?? []
        }
        chapters = summary.chapters
        self.summary = summary
    }

    /// The chapters outlive the summary, so the Outline and the Info inspector keep showing them.
    mutating func removeSummary() {
        if chapters == nil { chapters = summary?.chapters }
        summary = nil
    }
}
