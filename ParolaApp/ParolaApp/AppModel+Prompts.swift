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

    func runPrompt(_ prompt: Prompt) {
        guard features.isEnabled(.ai) else { return }
        guard let transcript = self.transcript else { return }
        guard !isRunningPrompt else { return }
        isRunningPrompt = true
        promptOutput = nil
        let generation = derivedArtifactsGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try await makeLanguageModel(for: .prompts, instructions: prompt.instructions)
                let result = try await PromptRunner.run(prompt, on: transcript.promptText, model: model, features: features)
                if generation == derivedArtifactsGeneration {
                    promptOutput = PromptOutput(promptName: prompt.name, text: result)
                }
            } catch {
                if generation == derivedArtifactsGeneration {
                    promptOutput = PromptOutput(
                        promptName: prompt.name,
                        text: "",
                        failure: Self.promptFailureMessage(.prompt, error: error)
                    )
                }
                refreshAIAvailability()
            }
            isRunningPrompt = false
        }
    }

    func extractActionItems() {
        guard features.isEnabled(.ai) else { return }
        guard let transcript = self.transcript else { return }
        guard !isExtractingActionItems else { return }
        guard let prompt = Prompt.builtIns.first(where: { $0.name == "Action items" }) else { return }
        isExtractingActionItems = true
        actionItemsError = nil
        let generation = derivedArtifactsGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try await makeLanguageModel(for: .prompts, instructions: prompt.instructions)
                let result = try await PromptRunner.run(prompt, on: transcript.promptText, model: model, features: features)
                if generation == derivedArtifactsGeneration {
                    actionItems = ActionItemParser.parse(result)
                }
            } catch {
                if generation == derivedArtifactsGeneration {
                    actionItemsError = Self.promptFailureMessage(.actionItems, error: error)
                }
                refreshAIAvailability()
            }
            isExtractingActionItems = false
        }
    }

    func clearActionItems() {
        actionItems = []
    }

    /// Drops LLM output and undo history tied to the previous transcript. Call wherever a different transcript installs.
    func clearDerivedArtifacts() {
        // Whole stack, not just our target: field-editor typing undo shares the window's manager and is stale context too.
        undoManager?.removeAllActions()
        // Segment ids are positions, not identities, so a reveal left over from the last transcript would hold an unrelated line in the next one.
        pendingRevealSegmentID = nil
        derivedArtifactsGeneration &+= 1
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
    }

    /// A subtitles fetch brings no bundle and no media, so this swap is the whole handover: no entry, and the same seam a stored document takes.
    func installFetchedSubtitles(_ fetched: Transcript) {
        selectedEntryID = nil
        installStoredTranscript(fetched)
    }

    /// Call after the transcript installs — `clearDerivedArtifacts()` runs before it, and Chapters reads runtime state only.
    func adoptSavedChapters() {
        let saved = transcript?.summary?.chapters ?? []
        if smartChapters != saved { smartChapters = saved }
    }

    /// Keeps a saved summary's chapters in step with the runtime list; unsaved entries keep theirs in memory only.
    func persistChapters(_ chapters: [Chapter]) {
        guard transcript?.summary != nil, transcript?.summary?.chapters != chapters else { return }
        transcript?.summary?.chapters = chapters
        guard let entryID = selectedEntryID, let updated = transcript else { return }
        Task { [library] in
            try? await library.updateTranscript(updated, for: entryID, reindex: false)
        }
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
        guard features.isEnabled(.ai) else { return }
        guard let transcript = self.transcript else { return }
        guard !isExtractingChapters else { return }
        isExtractingChapters = true
        chaptersError = nil
        let generation = derivedArtifactsGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try await makeLanguageModel(for: .summary, instructions: nil)
                let chapters = try await SmartChapters.generate(for: transcript, model: model)
                if generation == derivedArtifactsGeneration {
                    smartChapters = chapters
                    persistChapters(chapters)
                }
            } catch {
                if generation == derivedArtifactsGeneration {
                    chaptersError = Self.promptFailureMessage(.chapterExtraction, error: error)
                }
                refreshAIAvailability()
            }
            isExtractingChapters = false
        }
    }

    func clearSmartChapters() {
        smartChapters = []
        persistChapters([])
    }

    /// Writes the card title and one-line summary for a saved entry, honoring the generation toggle.
    /// Best-effort: failures only log. Returns the written metadata, or nil when skipped or failed.
    @discardableResult
    func generateCardMetadata(for id: LibraryEntry.ID, transcript: Transcript) async -> CardMetadata? {
        guard generatesCardMetadata else { return nil }
        return await writeCardMetadata(for: id, transcript: transcript)
    }

    /// An explicit user request from the Info inspector: bypasses the generation toggle, still needs the AI feature.
    func regenerateCardMetadata() {
        guard let id = selectedEntryID, let transcript else { return }
        Task { [weak self] in await self?.regenerateCardMetadata(for: id, transcript: transcript) }
    }

    /// The same explicit request, aimed at a named entry: what the bridge's `force` routes to.
    @discardableResult
    func regenerateCardMetadata(for id: LibraryEntry.ID, transcript: Transcript) async -> CardMetadata? {
        await writeCardMetadata(for: id, transcript: transcript)
    }

    /// Blank custom prompts fall back to the built-in instructions instead of being sent as empty text.
    static func resolvedPrompt(_ raw: String) -> String? {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
    }

    @discardableResult
    private func writeCardMetadata(for id: LibraryEntry.ID, transcript: Transcript) async -> CardMetadata? {
        guard features.isEnabled(.ai) else { return nil }
        if let cardMetadataOperation {
            guard let meta = await cardMetadataOperation(transcript) else { return nil }
            try? await library.setCardMetadata(aiTitle: meta.title, shortSummary: meta.summary, for: id)
            await refreshLibraryAndWait()
            return meta
        }
        let prompts = CardMetadataPrompts(
            title: Self.resolvedPrompt(customTitlePrompt),
            summary: Self.resolvedPrompt(customSummaryPrompt)
        )
        do {
            let meta = try await CardMetadataService.generate(for: transcript, prompts: prompts, features: features)
            // A run the 30 s timeout gave up on must not land on top of a manual regenerate.
            guard !Task.isCancelled else { return nil }
            try await library.setCardMetadata(aiTitle: meta.title, shortSummary: meta.summary, for: id)
            await refreshLibraryAndWait()
            return meta
        } catch CardMetadataService.Failure.tooShort {
            return nil
        } catch {
            ParolaLog.notice(.ai, "card metadata skipped", [.error: .error(error)])
            return nil
        }
    }

    func generateYouTubeChapters() {
        guard features.isEnabled(.ai) else { return }
        guard let transcript = self.transcript else { return }
        guard !isRunningPrompt else { return }
        isRunningPrompt = true
        promptOutput = nil
        let generation = derivedArtifactsGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try await makeLanguageModel(for: .summary, instructions: nil)
                let result = try await YouTubeChapters.generate(for: transcript, model: model)
                if generation == derivedArtifactsGeneration {
                    promptOutput = PromptOutput(promptName: "YouTube Chapters", text: result)
                }
            } catch {
                if generation == derivedArtifactsGeneration {
                    promptOutput = PromptOutput(
                        promptName: "YouTube Chapters",
                        text: "",
                        failure: Self.promptFailureMessage(.chapterGeneration, error: error)
                    )
                }
                refreshAIAvailability()
            }
            isRunningPrompt = false
        }
    }
}
