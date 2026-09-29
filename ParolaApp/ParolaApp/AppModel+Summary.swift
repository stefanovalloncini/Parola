import Foundation
import ParolaCore

extension AppModel {
    var isSummarising: Bool { aiJobs.isRunning(.summary, for: selectedEntryID) }

    func summariseTranscript(options: SummaryOptions? = nil) {
        guard let transcript else { return }
        summarise(entry: selectedEntryID, transcript: transcript, options: options)
    }

    /// The one way a summary starts: it lands on `entryID` whatever is on screen by then (nil: an unsaved transcript).
    @discardableResult
    func summarise(entry entryID: LibraryEntry.ID?, transcript: Transcript, options: SummaryOptions? = nil) -> Task<Summary, any Error>? {
        startSummary(for: entryID, transcript: transcript, options: options ?? summaryOptions, summarise: makeSummariser(), forChat: false)
    }

    /// A summary a chat starts keeps the chapters the entry already has.
    private func startSummary(
        for entryID: LibraryEntry.ID?,
        transcript: Transcript,
        options: SummaryOptions,
        summarise: @escaping @Sendable (Transcript, SummaryOptions) async throws -> Summary,
        forChat: Bool
    ) -> Task<Summary, any Error>? {
        guard features.isEnabled(.ai) else { return nil }
        let artifacts = derivedArtifactsGeneration
        if entryID == selectedEntryID { summaryError = nil }
        return aiJobs.start(
            .summary,
            for: entryID,
            work: { try await summarise(transcript, options) },
            land: { [weak self] summary, entryID in
                await self?.landSummary(summary, for: entryID, askedAt: artifacts, keepingChapters: forChat)
            },
            fail: { [weak self] error, entryID in
                guard let self else { return }
                if isOnScreen(entryID, askedAt: artifacts) { summaryError = error.localizedDescription }
                refreshAIAvailability()
            }
        )
    }

    /// The autostart rule for a run that just landed: a transcript long enough gets a summary when the setting is on.
    func applyAutostartSummary(to entryID: LibraryEntry.ID, transcript: Transcript) {
        guard autostartSummary, features.isEnabled(.ai),
              transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= CardMetadataService.minimumCharacters
        else { return }
        summarise(entry: entryID, transcript: transcript)
    }

    /// Disk first, then the pane if the entry is on screen by then, so an open racing the landing can't keep a copy without it.
    private func landSummary(
        _ summary: Summary,
        for entryID: LibraryEntry.ID?,
        askedAt artifacts: Int,
        keepingChapters: Bool
    ) async {
        if let entryID {
            do {
                try await library.mutateTranscript(for: entryID) { $0.install(summary: summary, keepingChapters: keepingChapters) }
            } catch {
                ParolaLog.error(.library, "summary could not be saved to the library", [.error: .error(error)])
            }
        }
        guard isOnScreen(entryID, askedAt: artifacts) else { return }
        transcript?.install(summary: summary, keepingChapters: keepingChapters)
        adoptSavedChapters()
    }

    /// Whether a run's transcript is on screen: the same entry, or for an unsaved one the same install.
    func isOnScreen(_ entryID: LibraryEntry.ID?, askedAt artifacts: Int) -> Bool {
        guard let entryID else { return selectedEntryID == nil && derivedArtifactsGeneration == artifacts }
        return entryID == selectedEntryID
    }

    /// Writes a summary with the model `task` is set to, labelled with that model.
    func makeSummariser(for task: LanguageModelTask = .summary) -> @Sendable (Transcript, SummaryOptions) async throws -> Summary {
        let makeModel = summaryModelMaker(for: task)
        let budget = tokenBudget(for: task)
        let provider = languageModelLabel(for: task)
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

    /// What a long chat condenses around: the entry's summary, the summary run already writing it, or a new one.
    func chatDigest(for entryID: LibraryEntry.ID?, transcript: Transcript) -> @Sendable () async throws -> Summary {
        { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.summaryForChat(entryID: entryID, transcript: transcript)
        }
    }

    private func summaryForChat(entryID: LibraryEntry.ID?, transcript: Transcript) async throws -> Summary {
        if entryID == selectedEntryID, let shown = self.transcript?.summary, !shown.text.isEmpty { return shown }
        let run = aiJobs.running(.summary, for: entryID, as: Summary.self) ?? startSummary(
            for: entryID,
            transcript: transcript,
            options: summaryOptions,
            summarise: makeSummariser(for: digestTask),
            forChat: true
        )
        guard let run else { throw CancellationError() }
        return try await run.value
    }

    /// The summary model writes the digest, unless it would take the transcript somewhere the chat's model doesn't.
    var digestTask: LanguageModelTask {
        resolvedLanguageModelChoice(for: .summary).isRemote == resolvedLanguageModelChoice(for: .chat).isRemote ? .summary : .chat
    }

    /// The bridge's write path for the saved options, so it goes through a seam like its four
    /// JSON-backed siblings; the options column binds to the property directly.
    func setSummaryOptions(_ options: SummaryOptions) {
        guard options != summaryOptions else { return }
        summaryOptions = options
    }

    func clearSummary() {
        aiJobs.cancel(.summary, for: selectedEntryID)
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
    /// With `keepingChapters`, chapters the transcript already has win over the summary's.
    mutating func install(summary: Summary, keepingChapters: Bool) {
        var summary = summary
        if keepingChapters, !(chapters ?? []).isEmpty { summary.chapters = [] }
        install(summary: summary)
    }

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
