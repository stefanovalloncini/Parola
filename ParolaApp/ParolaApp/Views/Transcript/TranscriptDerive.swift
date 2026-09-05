import Foundation

enum TranscriptDerive {
    /// Up to this many segments the derive fits inside a frame, so it runs inline and the list never lands late.
    static let synchronousCap = 200

    /// Silence at least this long between two segments reads as a new paragraph in the continuous transcript.
    static let paragraphPauseSeconds: TimeInterval = 1.5
}
