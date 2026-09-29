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
        let summarise = makeSummariser()
        Task { [weak self] in
            do {
                let summary = try await summarise(snapshot, resolvedOptions)
                guard let self, generation == summaryGeneration else { return }
                // A nil entry id means the transcript wasn't in the library yet: persistToLibrary
                // selects it moments later, and that late selection owns this summary.
                guard self.derivedArtifactsGeneration == artifacts,
                      entryID == nil || self.selectedEntryID == entryID else { isSummarising = false; return }
                self.transcript?.install(summary: summary)
                adoptSavedChapters()
                isSummarising = false
                if let entryID = self.selectedEntryID, let installed = self.transcript {
                    Task { [library] in
                        try? await library.setSummary(installed.summary, chapters: installed.chapters, for: entryID)
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

    /// Writes a summary with the model the summary task is set to, labelled with that model.
    func makeSummariser() -> @Sendable (Transcript, SummaryOptions) async throws -> Summary {
        let makeModel = summaryModelMaker()
        let budget = tokenBudget(for: .summary)
        let provider = languageModelLabel(for: .summary)
        let summarise = summariseOperation ?? { [features] transcript, options in
            guard let makeModel else {
                return try await SummaryService(budget: budget, features: features).summarise(transcript, options: options)
            }
            return try await SummaryService(budget: budget, features: features, makeModel: makeModel)
                .summarise(transcript, options: options)
        }
        return { transcript, options in
            var summary = try await summarise(transcript, options)
            summary.provider = provider
            return summary
        }
    }

    /// What a chat condenses a long transcript around when the entry has no summary: written the way
    /// Summarise writes one and kept as the entry's summary, so the next chat starts from it.
    func chatDigest(for entryID: LibraryEntry.ID?, transcript: Transcript) -> @Sendable () async throws -> Summary {
        let summarise = makeSummariser()
        let options = summaryOptions
        return { [weak self] in
            if let saved = await self?.shownSummary(for: entryID) { return saved }
            let summary = try await summarise(transcript, options)
            await self?.keepChatDigest(summary, for: entryID)
            return summary
        }
    }

    private func shownSummary(for entryID: LibraryEntry.ID?) -> Summary? {
        guard let entryID, entryID == selectedEntryID, let summary = transcript?.summary, !summary.text.isEmpty else { return nil }
        return summary
    }

    /// A summary the user asked for in the meantime wins; the digest only fills an empty place.
    func keepChatDigest(_ summary: Summary, for entryID: LibraryEntry.ID?) async {
        guard let entryID else { return }
        if entryID == selectedEntryID, transcript?.summary == nil {
            transcript?.install(summary: summary)
            adoptSavedChapters()
        }
        do {
            try await library.mutateTranscript(for: entryID) { stored in
                guard stored.summary == nil else { return }
                stored.install(summary: summary)
            }
        } catch {
            ParolaLog.error(.library, "chat digest could not be kept as the summary", [.error: .error(error)])
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
            let chapters = transcript?.chapters
            Task { [library] in
                try? await library.setSummary(nil, chapters: chapters, for: entryID)
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
        case .transcript: return hasTranscript
        case .summary, .chat: return hasTranscript && features.isEnabled(.ai)
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
