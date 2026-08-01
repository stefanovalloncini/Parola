import Foundation

enum TranscriptDerive {
    /// Up to this many segments the derive fits inside a frame, so it runs inline and the list never lands late.
    static let synchronousCap = 200
}
