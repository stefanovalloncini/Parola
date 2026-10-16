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

/// Drops segments whose entire text matches one of the rule patterns, ignoring case, surrounding
/// whitespace and surrounding punctuation. Patterns are matched against the full segment text, not
/// as substrings — a pattern of `"uh"` filters "Uh." but not "uh huh". A pattern made only of
/// punctuation, like "♪", matches any segment that is only punctuation.
public enum IgnoredSegments {
    public static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: trimmed)
    }

    public static func apply(
        rules: [IgnoredSegmentRule],
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let patterns: Set<String> = Set(
            rules
                .filter(\.enabled)
                .filter { !$0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { normalized($0.pattern) }
        )
        guard !patterns.isEmpty else { return segments }
        return segments.filter { !patterns.contains(normalized($0.text)) }
    }

    /// Drops the built-in ``HallucinationPhrases`` list. Kept apart from ``apply(rules:to:)``
    /// so a frontend that already ran this pass doesn't run it a second time over user rules.
    public static func applyBuiltInDefaults(
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        segments.filter { !HallucinationPhrases.matchSet.contains(normalized($0.text)) }
    }

    private static let trimmed = CharacterSet(charactersIn: ".!?…。！？,、♪-—¡¿")
        .union(.whitespacesAndNewlines)
}
