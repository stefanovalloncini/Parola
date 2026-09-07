import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func scheduleRecomputeMatches() {
        matchesDebounce?.cancel()
        guard findIsOpen, let transcript else {
            applyMatches([])
            return
        }
        let clock = clock
        let query = findQuery
        let caseSensitive = findCaseSensitive
        matchesDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150), clock: clock)
            guard !Task.isCancelled else { return }
            if !query.isEmpty { self?.lastFindQuery = query }
            let result = await Task.detached {
                transcript.findMatches(query, caseSensitive: caseSensitive)
            }.value
            guard !Task.isCancelled else { return }
            self?.applyMatches(result)
        }
    }

    func recomputeMatches() {
        guard findIsOpen, let transcript else {
            applyMatches([])
            return
        }
        applyMatches(transcript.findMatches(findQuery, caseSensitive: findCaseSensitive))
    }

    private func applyMatches(_ result: [TranscriptMatch]) {
        matches = result
        currentMatchIndex = min(currentMatchIndex, max(matches.count - 1, 0))
        snapToCurrentMatch()
    }

    /// The index matches tokens, not substrings, so the jump stands alone and Find opens only on a query a segment holds.
    func revealInTranscript(_ query: String, at firstHit: LibrarySearchIndex.Match.FirstHit? = nil) {
        guard let transcript else { return }
        if let firstHit, let id = Self.revealTarget(for: firstHit, in: transcript.segments) {
            currentSegmentID = id
            pendingRevealSegmentID = id
        }
        guard !transcript.findMatches(query, caseSensitive: findCaseSensitive).isEmpty else { return }
        findIsOpen = true
        // The 150 ms recompute this starts re-snaps the selection to the first Find match.
        if findQuery == query { scheduleRecomputeMatches() } else { findQuery = query }
    }

    /// The index quantizes a boundary to hundredths, so a segment can start a few milliseconds past the time the row shows.
    private static let revealTimeTolerance = 0.005

    /// The row shows the hit's time, so the time picks the segment. `segmentIndex` is a position in
    /// an array the index built rather than the one `load` handed the app, so it stands only where
    /// its segment carries that time; a hit past the end of the transcript picks nothing at all.
    static func revealTarget(
        for hit: LibrarySearchIndex.Match.FirstHit,
        in segments: [TranscriptSegment]
    ) -> TranscriptSegment.ID? {
        if segments.indices.contains(hit.segmentIndex),
           abs(segments[hit.segmentIndex].start - hit.seconds) <= revealTimeTolerance {
            return segments[hit.segmentIndex].id
        }
        guard let last = segments.last, hit.seconds <= last.end + revealTimeTolerance else { return nil }
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].start <= hit.seconds + revealTimeTolerance { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? segments[low - 1].id : nil
    }

    /// Called by the transcript view once it has scrolled to the reveal; the player owns the selection again after it.
    func consumePendingReveal(_ id: TranscriptSegment.ID) {
        guard pendingRevealSegmentID == id else { return }
        pendingRevealSegmentID = nil
    }

    func goToNextMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        snapToCurrentMatch()
    }

    func goToPreviousMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        snapToCurrentMatch()
    }

    func replaceCurrentMatch() {
        guard let transcript, !matches.isEmpty else { return }
        let match = matches[currentMatchIndex]
        applyTranscriptEdit(
            transcript.applying(replacement: findReplacement, to: match),
            actionName: String(localized: "Replace")
        )
        recomputeMatches()
    }

    func replaceAllMatches() {
        guard let transcript, !findQuery.isEmpty else { return }
        applyTranscriptEdit(
            transcript.replacingAll(findQuery, with: findReplacement, caseSensitive: findCaseSensitive),
            actionName: String(localized: "Replace All")
        )
        recomputeMatches()
    }

    private func snapToCurrentMatch() {
        guard !matches.isEmpty else { return }
        let id = matches[currentMatchIndex].segmentID
        currentSegmentID = id
    }

    func match(in segmentID: TranscriptSegment.ID) -> [TranscriptMatch] {
        matchesBySegment[segmentID] ?? []
    }

    var currentMatch: TranscriptMatch? {
        guard !matches.isEmpty else { return nil }
        return matches[currentMatchIndex]
    }

    func rebuildMatchesIndex() {
        matchesBySegment = Dictionary(grouping: matches, by: \.segmentID)
    }
}
