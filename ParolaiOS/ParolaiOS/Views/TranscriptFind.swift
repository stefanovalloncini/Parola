import Foundation
import ParolaCore

enum TranscriptFind {
    static let debounce: Duration = .milliseconds(150)

    static func contains(_ text: String, query: String) -> Bool {
        guard !query.isEmpty else { return false }
        return (text as NSString).range(of: query, options: .caseInsensitive).location != NSNotFound
    }

    static func matchingIDs(in segments: [TranscriptSegment], query: String) -> [TranscriptSegment.ID] {
        guard !query.isEmpty else { return [] }
        return segments.compactMap { contains($0.text, query: query) ? $0.id : nil }
    }
}
