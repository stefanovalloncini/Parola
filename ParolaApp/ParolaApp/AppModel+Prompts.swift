import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    enum PromptFailure {
        case prompt
        case actionItems
        case chapterExtraction
        case chapterGeneration
    }

    nonisolated static func promptFailureMessage(_ kind: PromptFailure, error: Error, bundle: Bundle = .main) -> String {
        let reason = error.localizedDescription
        switch kind {
        case .prompt:
            return String(localized: "Prompt failed: \(reason)", bundle: bundle)
        case .actionItems:
            return String(localized: "Action item extraction failed: \(reason)", bundle: bundle)
        case .chapterExtraction:
            return String(localized: "Chapter extraction failed: \(reason)", bundle: bundle)
        case .chapterGeneration:
            return String(localized: "Chapter generation failed: \(reason)", bundle: bundle)
        }
    }

    var isRunningPrompt: Bool { aiJobs.isRunning(.prompt, for: selectedEntryID) }
    var isExtractingActionItems: Bool { aiJobs.isRunning(.actionItems, for: selectedEntryID) }
    var isExtractingChapters: Bool { aiJobs.isRunning(.chapters, for: selectedEntryID) }

    func runPrompt(_ prompt: Prompt) {
        guard features.isEnabled(.ai), let transcript else { return }
        let budget = tokenBudget(for: .prompts)
        let features = features
        startPromptJob(named: prompt.name, failure: .prompt) { [weak self] in
            guard let self else { throw CancellationError() }
            let model = try await self.makeLanguageModel(for: .prompts, instructions: prompt.instructions)
            return try await PromptRunner.run(prompt, on: transcript, model: model, budget: budget, features: features)
        }
    }

    func generateYouTubeChapters() {
        guard features.isEnabled(.ai), let transcript else { return }
        let budget = tokenBudget(for: .summary)
        startPromptJob(named: "YouTube Chapters", failure: .chapterGeneration) { [weak self] in
            guard let self else { throw CancellationError() }
            let model = try await self.makeLanguageModel(for: .summary, instructions: nil)
            return try await YouTubeChapters.generate(for: transcript, model: model, budget: budget)
        }
    }

    /// A prompt's answer is shown, not saved, so it only appears while its transcript is still on screen.
    private func startPromptJob(
        named name: String,
        failure: PromptFailure,
        work: @escaping @Sendable () async throws -> String
    ) {
        let entryID = selectedEntryID
        let artifacts = derivedArtifactsGeneration
        let started = aiJobs.start(
            .prompt,
            for: entryID,
            work: work,
            land: { [weak self] text, entryID in
                guard let self, isOnScreen(entryID, askedAt: artifacts) else { return }
                promptOutput = PromptOutput(promptName: name, text: text)
            },
            fail: { [weak self] error, entryID in
                guard let self else { return }
                if isOnScreen(entryID, askedAt: artifacts) {
                    promptOutput = PromptOutput(promptName: name, text: "", failure: Self.promptFailureMessage(failure, error: error))
                }
                refreshAIAvailability()
            }
        )
        if started != nil { promptOutput = nil }
    }

    func extractActionItems() {
        guard features.isEnabled(.ai), let transcript else { return }
        guard let prompt = Prompt.builtIns.first(where: { $0.name == "Action items" }) else { return }
        let entryID = selectedEntryID
        let artifacts = derivedArtifactsGeneration
        let budget = tokenBudget(for: .prompts)
        let features = features
        let started = aiJobs.start(
            .actionItems,
            for: entryID,
            work: { [weak self] in
                guard let self else { throw CancellationError() }
                let model = try await self.makeLanguageModel(for: .prompts, instructions: prompt.instructions)
                let result = try await PromptRunner.run(
                    prompt, on: transcript, model: model, budget: budget, answer: .brief, features: features
                )
                return ActionItemParser.parse(result)
            },
            land: { [weak self] items, entryID in
                await self?.landActionItems(items, for: entryID, askedAt: artifacts)
            },
            fail: { [weak self] error, entryID in
                guard let self else { return }
                if isOnScreen(entryID, askedAt: artifacts) {
                    actionItemsError = Self.promptFailureMessage(.actionItems, error: error)
                }
                refreshAIAvailability()
            }
        )
        if started != nil { actionItemsError = nil }
    }

    private func landActionItems(_ items: [ActionItem], for entryID: LibraryEntry.ID?, askedAt artifacts: Int) async {
        if let entryID {
            do {
                try await library.setActionItems(items, for: entryID)
            } catch {
                ParolaLog.error(.library, "action items could not be saved to the library", [.error: .error(error)])
            }
        }
        guard isOnScreen(entryID, askedAt: artifacts) else { return }
        actionItems = items
        transcript?.actionItems = items
    }

    func clearActionItems() {
        aiJobs.cancel(.actionItems, for: selectedEntryID)
        actionItems = []
        guard transcript?.actionItems != nil else { return }
        transcript?.actionItems = nil
        guard let entryID = selectedEntryID else { return }
        Task { [library] in
            try? await library.setActionItems(nil, for: entryID)
        }
    }

    /// Drops LLM output and undo history tied to the previous transcript. Call wherever a different transcript installs.
    func clearDerivedArtifacts() {
        // Whole stack, not just our target: field-editor typing undo shares the window's manager and is stale context too.
        undoManager?.removeAllActions()
        // Segment ids are positions, not identities, so a reveal left over from the last transcript would hold an unrelated line in the next one.
        pendingRevealSegmentID = nil
        if editingSegmentNote != nil { editingSegmentNote = nil }
        derivedArtifactsGeneration &+= 1
        aiJobs.cancelUnsaved()
        if promptOutput != nil { promptOutput = nil }
        if !actionItems.isEmpty { actionItems = [] }
        if !smartChapters.isEmpty { smartChapters = [] }
        if actionItemsError != nil { actionItemsError = nil }
        if chaptersError != nil { chaptersError = nil }
    }

    /// The one way a stored document takes over the pane: drop what the last transcript derived, then adopt what this one saved.
    func installStoredTranscript(_ stored: Transcript) {
        clearDerivedArtifacts()
        transcript = stored
        adoptSavedChapters()
        if let saved = stored.actionItems, !saved.isEmpty { actionItems = saved }
    }

    /// A subtitles fetch brings no bundle and no media, so this swap is the whole handover: no entry, and the same seam a stored document takes.
    func installFetchedSubtitles(_ fetched: Transcript) {
        selectedEntryID = nil
        installStoredTranscript(fetched)
    }

    /// Call after the transcript installs — `clearDerivedArtifacts()` runs before it, and Chapters reads runtime state only.
    func adoptSavedChapters() {
        let saved = transcript.map { $0.chapters ?? $0.summary?.chapters ?? [] } ?? []
        if smartChapters != saved { smartChapters = saved }
    }

    /// Chapters keep a place of their own, so an entry without a summary keeps them; a summary gets a copy, where exports read them.
    func persistChapters(_ chapters: [Chapter]) {
        guard installChapters(chapters), let entryID = selectedEntryID else { return }
        Task { [library] in
            try? await library.setChapters(chapters, for: entryID)
        }
    }

    /// Puts the chapters on the transcript on screen, and on its summary's copy; false when nothing changed.
    @discardableResult
    private func installChapters(_ chapters: [Chapter]) -> Bool {
        guard var updated = transcript else { return false }
        updated.chapters = chapters
        updated.summary?.chapters = chapters
        guard updated != transcript else { return false }
        transcript = updated
        return true
    }

    /// Re-reads whether Apple Intelligence can serve a request, so AI affordances can gate on it
    /// before the user clicks. Safe to call from `.task` — it doesn't load the model.
    func refreshAIAvailability() {
        guard features.isEnabled(.ai) else { return }
        Task { [weak self] in
            let availability = await LanguageModelFactory.onDeviceAvailability()
            self?.aiUnavailableReason = availability.reason
        }
    }

    func extractSmartChapters() {
        guard features.isEnabled(.ai), let transcript else { return }
        let entryID = selectedEntryID
        let artifacts = derivedArtifactsGeneration
        let budget = tokenBudget(for: .summary)
        let started = aiJobs.start(
            .chapters,
            for: entryID,
            work: { [weak self] in
                guard let self else { throw CancellationError() }
                let model = try await self.makeLanguageModel(for: .summary, instructions: nil)
                return try await SmartChapters.generate(for: transcript, model: model, budget: budget)
            },
            land: { [weak self] chapters, entryID in
                await self?.landChapters(chapters, for: entryID, askedAt: artifacts)
            },
            fail: { [weak self] error, entryID in
                guard let self else { return }
                if isOnScreen(entryID, askedAt: artifacts) {
                    chaptersError = Self.promptFailureMessage(.chapterExtraction, error: error)
                }
                refreshAIAvailability()
            }
        )
        if started != nil { chaptersError = nil }
    }

    private func landChapters(_ chapters: [Chapter], for entryID: LibraryEntry.ID?, askedAt artifacts: Int) async {
        if let entryID {
            do {
                try await library.setChapters(chapters, for: entryID)
            } catch {
                ParolaLog.error(.library, "chapters could not be saved to the library", [.error: .error(error)])
            }
        }
        guard isOnScreen(entryID, askedAt: artifacts) else { return }
        smartChapters = chapters
        installChapters(chapters)
    }

    func clearSmartChapters() {
        aiJobs.cancel(.chapters, for: selectedEntryID)
        smartChapters = []
        persistChapters([])
    }

    /// Writes the card title and one-line summary for a saved entry, honoring the generation toggle.
    /// Best-effort: failures only log. Returns the written metadata, or nil when skipped or failed.
    @discardableResult
    func generateCardMetadata(for id: LibraryEntry.ID, transcript: Transcript) async -> CardMetadata? {
        guard generatesCardMetadata else { return nil }
        return await writeCardMetadata(for: id, transcript: transcript).written
    }

    /// An explicit user request from the Info inspector: bypasses the generation toggle, still needs the AI feature.
    func regenerateCardMetadata() {
        guard let id = selectedEntryID, let transcript else { return }
        Task { [weak self] in await self?.regenerateCardMetadata(for: id, transcript: transcript) }
    }

    /// The same explicit request, aimed at a named entry: what the bridge's `force` routes to.
    @discardableResult
    func regenerateCardMetadata(for id: LibraryEntry.ID, transcript: Transcript) async -> CardMetadata? {
        await writeCardMetadata(for: id, transcript: transcript).written
    }

    /// Blank custom prompts fall back to the built-in instructions instead of being sent as empty text.
    static func resolvedPrompt(_ raw: String) -> String? {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
    }

    enum CardMetadataOutcome: Sendable {
        case written(CardMetadata)
        /// Nothing a second try could change: the AI feature is off or the transcript is too short.
        case skipped
        case failed

        var written: CardMetadata? {
            if case .written(let meta) = self { return meta }
            return nil
        }
    }

    func writeCardMetadata(for id: LibraryEntry.ID, transcript: Transcript) async -> CardMetadataOutcome {
        guard features.isEnabled(.ai) else { return .skipped }
        if let cardMetadataOperation {
            guard let meta = await cardMetadataOperation(transcript) else { return .failed }
            guard !Task.isCancelled else { return .failed }
            if let entry = try? await library.setCardMetadata(aiTitle: meta.title, shortSummary: meta.summary, for: id) {
                landCardMetadata(entry)
            }
            return .written(meta)
        }
        let prompts = CardMetadataPrompts(
            title: Self.resolvedPrompt(customTitlePrompt),
            summary: Self.resolvedPrompt(customSummaryPrompt)
        )
        do {
            let meta = try await CardMetadataService.generate(for: transcript, prompts: prompts, features: features)
            // A run the timeout gave up on must not land on top of a manual regenerate.
            guard !Task.isCancelled else { return .failed }
            landCardMetadata(try await library.setCardMetadata(aiTitle: meta.title, shortSummary: meta.summary, for: id))
            return .written(meta)
        } catch {
            let outcome = Self.cardOutcome(after: error, modelOutOfReach: LanguageModelFactory.onDeviceIsOutOfReach())
            if case .failed = outcome { ParolaLog.notice(.ai, "card metadata skipped", [.error: .error(error)]) }
            return outcome
        }
    }

    /// Only a failure a later try could change is worth one: not a short transcript, not a Mac the model can't run on.
    nonisolated static func cardOutcome(after error: any Error, modelOutOfReach: Bool) -> CardMetadataOutcome {
        if let failure = error as? CardMetadataService.Failure, failure == .tooShort || failure == .featureDisabled {
            return .skipped
        }
        if error is LanguageModelFactory.Failure, modelOutOfReach { return .skipped }
        return .failed
    }

    private func landCardMetadata(_ entry: LibraryEntry) {
        let landing = Self.landingSignposter.beginInterval("card")
        landLibraryEntry(entry)
        Self.landingSignposter.endInterval("card", landing)
    }
}
