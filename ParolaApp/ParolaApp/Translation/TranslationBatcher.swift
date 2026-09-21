import Foundation
import ParolaCore
import Translation

/// Decides what goes into each translation call and where the answers land. The session does the
/// talking; everything here is pure, so batch sizes and id mapping are testable without a language pack.
enum TranslationBatcher {
    typealias Unit = (id: Int, text: String)

    static let maxBatchSize = 60

    /// The segments worth translating, trimmed. A blank segment has nothing to send.
    static func units(from segments: [TranscriptSegment]) -> [Unit] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (id: segment.id, text: text)
        }
    }

    static func batches(_ units: [Unit], limit: Int = maxBatchSize) -> [[Unit]] {
        guard limit > 0 else { return units.isEmpty ? [] : [units] }
        return stride(from: 0, to: units.count, by: limit).map {
            Array(units[$0..<min($0 + limit, units.count)])
        }
    }

    static func requests(for batch: [Unit]) -> [TranslationSession.Request] {
        batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
    }

    static func reassemble(_ responses: [TranslationSession.Response]) -> [Int: String] {
        var out: [Int: String] = [:]
        for response in responses {
            guard let identifier = response.clientIdentifier, let id = Int(identifier) else { continue }
            out[id] = response.targetText
        }
        return out
    }
}
