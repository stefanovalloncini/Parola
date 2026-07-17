import Foundation

public enum HotkeyEvent: Sendable {
    case press
    case release
}

public protocol HotkeyMonitor: AnyObject, Sendable {
    /// Begins listening for the configured hotkey. Replaces any previously installed handler.
    /// Implementations must release the prior closure to avoid leaks when `start` is called
    /// repeatedly (e.g. on settings changes).
    func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async
    /// Stops listening and releases the installed handler.
    func stop() async
}

public protocol TextInserter: Sendable {
    /// Inserts text into the frontmost app's focused control. Implementations that
    /// cannot reach the target should leave the text on the general pasteboard,
    /// then throw an error whose description tells the user how to recover.
    func insert(_ text: String) async throws
}

public protocol DictationRecorder: Sendable {
    /// Starts recording from the mic. Subsequent `start` calls before `stop` are a no-op.
    func start() async throws
    /// Stops recording and transcribes the captured audio. Returns the transcript text.
    func stopAndTranscribe() async throws -> String
    /// Stops recording and throws the captured audio away. Must not transcribe (or download
    /// a model): it runs on abort paths that only need the mic released promptly.
    func stopAndDiscard() async
    /// Emits a normalised 0...1 amplitude per captured audio buffer while recording.
    func levels() async -> AsyncStream<Float>
    /// Emits partial transcription text as the recorder receives confidence-rising guesses.
    /// May emit nothing for non-streaming backends.
    func partials() async -> AsyncStream<String>
}

public extension DictationRecorder {
    func stopAndDiscard() async {
        _ = try? await stopAndTranscribe()
    }
    func levels() async -> AsyncStream<Float> {
        AsyncStream { $0.finish() }
    }
    func partials() async -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}
