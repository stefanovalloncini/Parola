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
