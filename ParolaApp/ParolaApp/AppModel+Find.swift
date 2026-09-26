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

    /// Scans now and drops the debounced scan an edit's `transcript` write just queued, so a Replace scans once.
    func recomputeMatches() {
        matchesDebounce?.cancel()
        guard findIsOpen, let transcript else {
            applyMatches([])
            return
        }
        if !findQuery.isEmpty, lastFindQuery != findQuery { lastFindQuery = findQuery }
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
        guard Self.transcriptHasMatch(query, caseSensitive: findCaseSensitive, in: transcript.segments) else { return }
        findIsOpen = true
        // The 150 ms recompute this starts re-snaps the selection to the first Find match.
        if findQuery == query { scheduleRecomputeMatches() } else { findQuery = query }
    }

    /// Stops at the first hit instead of collecting every one, so a Find-closed jump doesn't rescan the whole transcript twice.
    static func transcriptHasMatch(_ query: String, caseSensitive: Bool, in segments: [TranscriptSegment]) -> Bool {
        guard !query.isEmpty else { return false }
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return segments.contains { ($0.text as NSString).range(of: query, options: options).location != NSNotFound }
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
        findReplacements &+= 1
    }

    func replaceAllMatches() {
        guard let transcript, !findQuery.isEmpty else { return }
        applyTranscriptEdit(
            transcript.replacingAll(findQuery, with: findReplacement, caseSensitive: findCaseSensitive),
            actionName: String(localized: "Replace All")
        )
        recomputeMatches()
        findReplacements &+= 1
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
