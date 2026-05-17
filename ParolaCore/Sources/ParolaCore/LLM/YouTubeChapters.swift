import Foundation

public enum YouTubeChapters {
    public static func generate(for transcript: Transcript, model: any LanguageModel) async throws -> String {
        var input = ""
        for segment in transcript.segments {
            let ts = Timecode.format(segment.start)
            input += "\(ts)  \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        let envelope = """
        Produce 5-10 YouTube chapter markers from the transcript below. Output exactly the markers and nothing else. Each marker on its own line in the form 'MM:SS Title' (or 'HH:MM:SS Title' for videos over an hour). The first marker MUST start at 00:00. Title is 3-7 words. No bullets, no quotes, no explanation.

        Transcript:
        \(input)
        """
        return try await model.respond(to: envelope)
    }
}
