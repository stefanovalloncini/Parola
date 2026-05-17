import Foundation

public struct IgnoredSegmentRule: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var pattern: String
    public var enabled: Bool

    public init(id: UUID = UUID(), pattern: String, enabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.enabled = enabled
    }
}

/// Drops segments whose entire text matches one of the rule patterns after trimming and
/// lowercasing. Patterns are matched against the full segment text, not as substrings —
/// a pattern of `"uh"` only filters a segment whose text is exactly "uh" (modulo case
/// and surrounding whitespace).
public enum IgnoredSegments {
    public static func apply(
        rules: [IgnoredSegmentRule],
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let patterns = rules
            .filter(\.enabled)
            .map { $0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !patterns.isEmpty else { return segments }
        return segments.filter { seg in
            let normalized = seg.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !patterns.contains(normalized)
        }
    }
}
