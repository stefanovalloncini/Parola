import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func scheduleRecomputeMatches() {
        matchesDebounce?.cancel()
        let clock = clock
        matchesDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150), clock: clock)
            guard !Task.isCancelled else { return }
            self?.recomputeMatches()
        }
    }

    func recomputeMatches() {
        guard findIsOpen, let transcript else {
            matches = []
            currentMatchIndex = 0
            return
        }
        matches = transcript.findMatches(findQuery, caseSensitive: findCaseSensitive)
        currentMatchIndex = min(currentMatchIndex, max(matches.count - 1, 0))
        snapToCurrentMatch()
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
        self.transcript = transcript.applying(replacement: findReplacement, to: match)
        recomputeMatches()
    }

    func replaceAllMatches() {
        guard let transcript, !findQuery.isEmpty else { return }
        self.transcript = transcript.replacingAll(findQuery, with: findReplacement, caseSensitive: findCaseSensitive)
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
