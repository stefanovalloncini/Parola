import Foundation

public enum YouTubeChapters {
    /// The model's markers as it wrote them; a transcript sent in windows gets the merged markers, one per line.
    public static func generate(
        for transcript: Transcript,
        model: any LanguageModel,
        budget: TokenBudget
    ) async throws -> String {
        let markers = try await SmartChapters.markers(for: transcript, model: model, budget: budget, wholeCount: "5-10", ask: ask)
        guard markers.responses.count > 1 else { return markers.responses.first ?? "" }
        return markers.chapters.map { "\(Timecode.format($0.start)) \($0.title)" }.joined(separator: "\n")
    }

    private static func ask(_ ask: SmartChapters.Ask) -> String {
        SmartChapters.partNote(ask.part) + "Produce \(ask.markers) YouTube chapter markers from the transcript below. Output exactly the markers and nothing else. Each marker on its own line in the form 'MM:SS Title' (or 'HH:MM:SS Title' for videos over an hour). The first marker MUST start at \(ask.firstMarker). Title is 3-7 words. No bullets, no quotes, no explanation."
    }
}
