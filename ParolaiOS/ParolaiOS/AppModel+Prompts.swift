import Foundation
import SwiftUI
import ParolaCore

extension AppModel {
    func runPrompt(_ prompt: Prompt, on transcript: Transcript) {
        guard !isRunningPrompt else { return }
        isRunningPrompt = true
        promptOutput = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try await LanguageModelFactory.makeOnDevice(instructions: prompt.instructions)
                let result = try await PromptRunner.run(prompt, on: transcript, model: model, budget: .onDevice)
                promptOutput = PromptOutput(promptName: prompt.name, text: result)
            } catch {
                lastError = FailureText.message(for: error)
            }
            isRunningPrompt = false
        }
    }

    func generateYouTubeChapters(for transcript: Transcript) {
        guard !isRunningPrompt else { return }
        isRunningPrompt = true
        promptOutput = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try await LanguageModelFactory.makeOnDevice()
                let result = try await YouTubeChapters.generate(for: transcript, model: model, budget: .onDevice)
                promptOutput = PromptOutput(promptName: "YouTube Chapters", text: result)
            } catch {
                lastError = FailureText.message(for: error)
            }
            isRunningPrompt = false
        }
    }
}
