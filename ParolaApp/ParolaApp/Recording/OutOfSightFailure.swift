import Foundation

/// A take that failed, or stopped on its own, while Parola was in the background: the pill and the menu bar item hold it as stopped until Parola is next in front, so the ending is never silent.
struct OutOfSightFailure: Equatable {
    /// The Dock bounces for any failure; the pill and the menu bar item let a take go at Stop, so a transcription that fails after it doesn't bring them back.
    let includesTranscription: Bool
    private(set) var held: Int?
    private var weighed: Ending?

    /// A take's stop on its own and a failure that follows it are two endings, each weighed where it lands.
    private struct Ending: Equatable {
        let takeID: Int
        let failed: Bool
    }

    init(includesTranscription: Bool = false) {
        self.includesTranscription = includesTranscription
    }

    /// Each ending is weighed once, the first time a surface sees it: held only if Parola wasn't in front then. A take that stopped on its own counts as one that failed.
    mutating func holds(_ take: RecordingSession?, stoppedOnItsOwn: Bool = false, appActive: Bool) -> Bool {
        let failed = take.map { counts(failureOf: $0) } ?? false
        guard let take, stoppedOnItsOwn || failed else {
            held = nil
            weighed = nil
            return false
        }
        let ending = Ending(takeID: take.takeID, failed: failed)
        if weighed != ending {
            weighed = ending
            held = appActive ? nil : take.takeID
        }
        return held == take.takeID
    }

    private func counts(failureOf take: RecordingSession) -> Bool {
        guard case .failed = take.state else { return false }
        return includesTranscription || take.failedWhile != .transcribing
    }

    /// Parola came to the front, where the failure shows on its Stage or in a notice.
    mutating func release() {
        held = nil
    }
}
