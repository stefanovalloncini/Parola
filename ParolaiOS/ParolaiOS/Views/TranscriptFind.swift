import Foundation
import Observation
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

@MainActor
@Observable
final class TranscriptFindState {
    private(set) var appliedQuery = ""
    private(set) var matchIDs: [TranscriptSegment.ID] = []
    private(set) var matchSet: Set<TranscriptSegment.ID> = []
    var currentMatchIndex = 0

    @ObservationIgnored var debounce: Duration = TranscriptFind.debounce

    var targetMatchID: TranscriptSegment.ID? {
        guard !matchIDs.isEmpty else { return nil }
        return matchIDs[min(max(0, currentMatchIndex), matchIDs.count - 1)]
    }

    func queryChanged(_ raw: String, in segments: [TranscriptSegment]) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
        }
        currentMatchIndex = 0
        appliedQuery = trimmed
        apply(TranscriptFind.matchingIDs(in: segments, query: trimmed))
    }

    func segmentsChanged(_ segments: [TranscriptSegment], resetsPosition: Bool = false) {
        if resetsPosition { currentMatchIndex = 0 }
        apply(TranscriptFind.matchingIDs(in: segments, query: appliedQuery))
    }

    func advance() {
        guard !matchIDs.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matchIDs.count
    }

    private func apply(_ ids: [TranscriptSegment.ID]) {
        matchIDs = ids
        matchSet = Set(ids)
    }
}
