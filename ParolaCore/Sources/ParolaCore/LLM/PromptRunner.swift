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

    /// Runs `prompt` over the transcript's `promptText`, speaker labels kept. A transcript too long for
    /// `budget` is sent window by window, each small enough for an answer as long as itself, and the
    /// answers are joined in order.
    public static func run(
        _ prompt: Prompt,
        on transcript: Transcript,
        model: any LanguageModel,
        budget: TokenBudget,
        features: FeatureSet = .resolve()
    ) async throws -> String {
        try features.require(.ai)
        let windows = await TranscriptWindows.split(
            transcript,
            budget: budget,
            instructions: prompt.instructions,
            answer: .asLongAsInput,
            line: promptLine(for:),
            render: { buildUserMessage(for: prompt, text: $0.promptText) }
        )
        guard windows.count > 1 else {
            return try await model.respond(to: windows[0].text)
        }
        var answers: [String] = []
        for window in windows {
            answers.append(try await model.respond(to: window.text).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return answers.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The user turn for `text`. The prompt's instructions travel once, as the model's own
    /// instructions, so this carries only the input, marked as such unless the prompt answers it directly.
    public static func buildUserMessage(for prompt: Prompt, text: String) -> String {
        prompt.useSystemInstructions ? "Input:\n\(text)" : text
    }

    /// A segment's share of `promptText`, counted as if it opened a new speaker's turn.
    private static func promptLine(for segment: TranscriptSegment) -> String? {
        let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        guard let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines), !speaker.isEmpty else {
            return body + "\n"
        }
        return "\(speaker): \(body)\n"
    }
}
