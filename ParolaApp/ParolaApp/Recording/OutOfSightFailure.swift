import Foundation

/// A take that failed while Parola was in the background: the pill and the menu bar item hold it as stopped until Parola is next in front, so the failure is never silent.
struct OutOfSightFailure: Equatable {
    private(set) var held: Int?
    private var weighed: Int?

    /// Each failure is weighed once, the first time a surface sees it: held only if Parola wasn't in front then.
    mutating func holds(_ take: RecordingSession?, appActive: Bool) -> Bool {
        guard let take, case .failed = take.state else {
            held = nil
            weighed = nil
            return false
        }
        if weighed != take.takeID {
            weighed = take.takeID
            held = appActive ? nil : take.takeID
        }
        return held == take.takeID
    }

    /// Parola came to the front, where the failure shows on its Stage or in a notice.
    mutating func release() {
        held = nil
    }
}
