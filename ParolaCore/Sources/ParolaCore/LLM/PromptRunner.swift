import Foundation

public enum PromptRunner {
    public static func run(
        _ prompt: Prompt,
        on text: String,
        model: any LanguageModel,
        features: FeatureSet = .resolve()
    ) async throws -> String {
        try features.require(.ai)
        let envelope = buildUserMessage(for: prompt, text: text)
        return try await model.respond(to: envelope)
    }

    public static func buildUserMessage(for prompt: Prompt, text: String) -> String {
        if prompt.useSystemInstructions {
            return """
            \(prompt.instructions)

            Input:
            \(text)
            """
        }
        return text
    }
}
