import Foundation

public enum HotkeyEvent: Sendable {
    case press
    case release
}

public protocol HotkeyMonitor: Sendable {
    func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async
    func stop() async
}

public protocol TextInserter: Sendable {
    func insert(_ text: String) async
}

public protocol DictationRecorder: Sendable {
    /// Starts recording from the mic. Subsequent `start` calls before `stop` are a no-op.
    func start() async throws
    /// Stops recording and transcribes the captured audio. Returns the transcript text.
    func stopAndTranscribe() async throws -> String
}
