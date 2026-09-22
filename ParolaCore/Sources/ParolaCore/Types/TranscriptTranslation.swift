import Foundation

/// A transcript translated into one target language: the translated text of every segment that has
/// one, keyed by segment id. A transcript holds one translation at a time — translating again
/// replaces the whole value.
public struct TranscriptTranslation: Codable, Hashable, Sendable {
    public var targetLanguage: String
    public var segments: [Int: String]
    public var createdAt: Date
    public var provider: String

    public init(targetLanguage: String, segments: [Int: String], createdAt: Date, provider: String) {
        self.targetLanguage = targetLanguage
        self.segments = segments
        self.createdAt = createdAt
        self.provider = provider
    }

    /// The translation after a segment splits in two. Both halves get fresh ids: the first half of
    /// the split keeps the text, the second gets none, because no part of a translated sentence
    /// maps to half its source.
    public func afterSplit(of id: Int, into firstID: Int) -> TranscriptTranslation {
        guard let text = segments[id] else { return self }
        var out = self
        out.segments.removeValue(forKey: id)
        out.segments[firstID] = text
        return out
    }

    /// The translation after a segment absorbs the next one, joining both texts the way the merged
    /// segment joins its source texts.
    public func afterMerge(of id: Int, with nextID: Int) -> TranscriptTranslation {
        var out = self
        out.segments = Self.merging(segments, of: id, with: nextID)
        return out
    }

    /// The same join the merged segment's own text gets, applied to a bare id-to-text map.
    static func merging(_ segments: [Int: String], of id: Int, with nextID: Int) -> [Int: String] {
        var out = segments
        let joined = [segments[id], segments[nextID]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        out.removeValue(forKey: nextID)
        if joined.isEmpty {
            out.removeValue(forKey: id)
        } else {
            out[id] = joined
        }
        return out
    }

    /// The translation after a segment is deleted.
    public func afterDelete(of id: Int) -> TranscriptTranslation {
        var out = self
        out.segments.removeValue(forKey: id)
        return out
    }
}
