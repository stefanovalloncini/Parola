import AppKit
import Foundation
import ParolaCore

struct PromptDictationProcessor: TextPostProcessor {
    let defaultPrompt: Prompt?
    let overrides: [String: Prompt]

    init(prompt: Prompt?) {
        self.defaultPrompt = prompt
        self.overrides = [:]
    }

    init(defaultPrompt: Prompt?, overrides: [String: Prompt]) {
        self.defaultPrompt = defaultPrompt
        self.overrides = overrides
    }

    func process(_ text: String) async -> String {
        let bundleID = await frontmostBundleID()
        let prompt: Prompt? = (bundleID.flatMap { overrides[$0] }) ?? defaultPrompt
        guard let prompt else { return text }
        do {
            let model = try LanguageModelFactory.makeOnDevice(instructions: prompt.instructions)
            let result = try await PromptRunner.run(prompt, on: text, model: model)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? text : trimmed
        } catch {
            return text
        }
    }

    @MainActor
    private func frontmostBundleID() async -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
