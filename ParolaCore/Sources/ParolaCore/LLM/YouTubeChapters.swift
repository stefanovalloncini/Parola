import Foundation

public enum YouTubeChapters {
    public static func generate(for transcript: Transcript, model: any LanguageModel) async throws -> String {
        var input = ""
        for segment in transcript.segments {
            let ts = formatTimestamp(segment.start)
            input += "\(ts)  \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        let envelope = """
        Produce 5-10 YouTube chapter markers from the transcript below. Output exactly the markers and nothing else. Each marker on its own line in the form 'MM:SS Title' (or 'HH:MM:SS Title' for videos over an hour). The first marker MUST start at 00:00. Title is 3-7 words. No bullets, no quotes, no explanation.

        Transcript:
        \(input)
        """
        return try await model.respond(to: envelope)
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
