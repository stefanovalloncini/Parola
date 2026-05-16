import Foundation

public enum PromptRunner {
    public static func run(
        _ prompt: Prompt,
        on text: String,
        model: any LanguageModel
    ) async throws -> String {
        let envelope = """
        \(prompt.instructions)

        Input:
        \(text)
        """
        return try await model.respond(to: envelope)
    }
}
