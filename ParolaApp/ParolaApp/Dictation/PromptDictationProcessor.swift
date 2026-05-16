import Foundation
import ParolaCore

struct PromptDictationProcessor: TextPostProcessor {
    let prompt: Prompt?

    func process(_ text: String) async -> String {
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
}
