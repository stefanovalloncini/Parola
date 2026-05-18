import AppKit
import Foundation
import ParolaCore

struct PromptDictationProcessor: TextPostProcessor {
    let defaultPrompt: Prompt?
    let overrides: [String: Prompt]

    init(defaultPrompt: Prompt?, overrides: [String: Prompt]) {
        self.defaultPrompt = defaultPrompt
        self.overrides = overrides
    }

    func process(_ text: String) async -> String {
        let preprocessed = SentenceCapitalizer.applyTo(PronounCapitalizer.applyTo(VoiceCommands.applyTo(text)))
        let frontmost = await frontmostAppContext()
        let prompt: Prompt? = (frontmost.bundleID.flatMap { overrides[$0] }) ?? defaultPrompt
        guard let prompt else { return preprocessed }
        do {
            let situated = contextualizing(prompt, with: frontmost.name)
            let model = try LanguageModelFactory.makeOnDevice(instructions: situated.instructions)
            let result = try await PromptRunner.run(situated, on: preprocessed, model: model)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? preprocessed : trimmed
        } catch {
            return preprocessed
        }
    }

    private func contextualizing(_ prompt: Prompt, with appName: String?) -> Prompt {
        guard let appName, !appName.isEmpty else { return prompt }
        var copy = prompt
        copy.instructions = "Context: the user is dictating into \(appName).\n\n" + prompt.instructions
        return copy
    }

    @MainActor
    private func frontmostAppContext() async -> (bundleID: String?, name: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
        return (app.bundleIdentifier, app.localizedName)
    }
}
