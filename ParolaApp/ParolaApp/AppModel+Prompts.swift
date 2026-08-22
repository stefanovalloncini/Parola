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
                let model = try await LanguageModelFactory.makeOnDevice(instructions: prompt.instructions)
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
                let model = try await LanguageModelFactory.makeOnDevice(instructions: prompt.instructions)
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
        derivedArtifactsGeneration &+= 1
        if promptOutput != nil { promptOutput = nil }
        if !actionItems.isEmpty { actionItems = [] }
        if !smartChapters.isEmpty { smartChapters = [] }
        if actionItemsError != nil { actionItemsError = nil }
        if chaptersError != nil { chaptersError = nil }
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
                let model = try await LanguageModelFactory.makeOnDevice()
                let chapters = try await SmartChapters.generate(for: transcript, model: model)
                if generation == derivedArtifactsGeneration {
                    smartChapters = chapters
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
    }

    /// Replaces a freshly-saved entry's filename-derived title with a short LLM-written one.
    /// Best-effort: any failure leaves the original title untouched.
    func autoTitleEntry(_ id: LibraryEntry.ID, transcript: Transcript) {
        guard features.isEnabled(.ai) else { return }
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 40 else { return }
        let excerpt = String(text.prefix(2000))
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try await LanguageModelFactory.makeOnDevice(
                    instructions: "Write a concise, specific title of 3 to 6 words for this transcript. Reply with only the title — no quotes, no surrounding punctuation, no preamble."
                )
                let raw = try await model.respond(to: excerpt)
                let title = Self.sanitizedTitle(raw)
                guard !title.isEmpty else { return }
                renameEntry(id, to: title)
            } catch {
                // best-effort: keep the default title
            }
        }
    }

    static func sanitizedTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = title.firstIndex(of: "\n") { title = String(title[..<newline]) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”.,;: "))
        return String(title.prefix(80))
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
                let model = try await LanguageModelFactory.makeOnDevice()
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
