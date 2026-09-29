import Foundation

/// A capture whose file stopped taking writes partway. The file keeps everything written before the failure.
public struct CaptureInterrupted: LocalizedError, Sendable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }

    public var errorDescription: String? {
        "The recording stopped saving partway (\(reason)). What was saved is kept at \(url.path)."
    }
}
