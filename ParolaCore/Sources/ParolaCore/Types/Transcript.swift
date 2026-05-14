import Foundation

public struct TranscriptSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?

    public init(id: Int, start: Double, end: Double, text: String, speaker: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }

    public var duration: Double { end - start }
}

public struct Transcript: Codable, Hashable, Sendable {
    public var segments: [TranscriptSegment]
    public var language: String
    public var modelName: String
    public var sourceURL: URL?
    public var durationSeconds: Double?

    public init(
        segments: [TranscriptSegment],
        language: String,
        modelName: String,
        sourceURL: URL? = nil,
        durationSeconds: Double? = nil
    ) {
        self.segments = segments
        self.language = language
        self.modelName = modelName
        self.sourceURL = sourceURL
        self.durationSeconds = durationSeconds
    }

    public var text: String {
        segments.map(\.text).joined(separator: " ")
    }
}
