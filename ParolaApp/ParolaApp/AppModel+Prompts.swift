import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func runPrompt(_ prompt: Prompt) {
        guard let transcript = self.transcript else { return }
        guard !isRunningPrompt else { return }
        isRunningPrompt = true
        promptOutput = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try LanguageModelFactory.makeOnDevice(instructions: prompt.instructions)
                let result = try await PromptRunner.run(prompt, on: transcript.text, model: model)
                promptOutput = PromptOutput(promptName: prompt.name, text: result)
            } catch {
                phase = .failed(message: "Prompt failed: \(error.localizedDescription)")
            }
            isRunningPrompt = false
        }
    }

    func extractActionItems() {
        guard let transcript = self.transcript else { return }
        guard !isExtractingActionItems else { return }
        guard let prompt = Prompt.builtIns.first(where: { $0.name == "Action items" }) else { return }
        isExtractingActionItems = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try LanguageModelFactory.makeOnDevice(instructions: prompt.instructions)
                let result = try await PromptRunner.run(prompt, on: transcript.text, model: model)
                actionItems = ActionItemParser.parse(result)
            } catch {
                phase = .failed(message: "Action item extraction failed: \(error.localizedDescription)")
            }
            isExtractingActionItems = false
        }
    }

    func clearActionItems() {
        actionItems = []
    }

    func extractSmartChapters() {
        guard let transcript = self.transcript else { return }
        guard !isExtractingChapters else { return }
        isExtractingChapters = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try LanguageModelFactory.makeOnDevice()
                let chapters = try await SmartChapters.generate(for: transcript, model: model)
                smartChapters = chapters
            } catch {
                phase = .failed(message: "Chapter extraction failed: \(error.localizedDescription)")
            }
            isExtractingChapters = false
        }
    }

    func clearSmartChapters() {
        smartChapters = []
    }

    func generateYouTubeChapters() {
        guard let transcript = self.transcript else { return }
        guard !isRunningPrompt else { return }
        isRunningPrompt = true
        promptOutput = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try LanguageModelFactory.makeOnDevice()
                let result = try await YouTubeChapters.generate(for: transcript, model: model)
                promptOutput = PromptOutput(promptName: "YouTube Chapters", text: result)
            } catch {
                phase = .failed(message: "Chapter generation failed: \(error.localizedDescription)")
            }
            isRunningPrompt = false
        }
    }
}
