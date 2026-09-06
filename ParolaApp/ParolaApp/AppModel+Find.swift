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

    /// Opens a search result on its hit: the index's position selects the segment outright, and Find
    /// opens on the query so the next and previous hits are a keystroke away. Without a position —
    /// a title, summary or speaker match — there is nothing to open unless the body holds the query.
    func revealInTranscript(_ query: String, at firstHit: LibrarySearchIndex.Match.FirstHit? = nil) {
        guard let transcript else { return }
        if let firstHit, transcript.segments.indices.contains(firstHit.segmentIndex) {
            currentSegmentID = transcript.segments[firstHit.segmentIndex].id
        } else if transcript.findMatches(query, caseSensitive: findCaseSensitive).isEmpty {
            return
        }
        findIsOpen = true
        if findQuery == query { scheduleRecomputeMatches() } else { findQuery = query }
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
