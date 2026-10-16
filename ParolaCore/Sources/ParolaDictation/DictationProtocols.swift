import Foundation
import ParolaCore

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
    /// The inserter a take uses for its own text, resolved when the take is released so a later focus change doesn't retarget it.
    func bound(to configuration: DictationPipelineConfiguration?) async -> any TextInserter
}

public extension TextInserter {
    func bound(to configuration: DictationPipelineConfiguration?) async -> any TextInserter { self }
}

/// A take whose capture has stopped. Finalizing it may run while the next take records.
public struct DictationTake: Sendable {
    public let finalize: @Sendable () async throws -> String
    public let discard: @Sendable () async -> Void

    public init(
        finalize: @escaping @Sendable () async throws -> String,
        discard: @escaping @Sendable () async -> Void = {}
    ) {
        self.finalize = finalize
        self.discard = discard
    }
}

public protocol DictationRecorder: Sendable {
    /// Starts recording from the mic. Subsequent `start` calls before `stop` are a no-op.
    func start() async throws
    /// Starts a take with the settings read at the press.
    func start(configuration: DictationPipelineConfiguration) async throws
    /// Stops recording and releases the mic at once; the returned take transcribes what was captured.
    func stopCapture() async throws -> DictationTake
    /// Stops recording and transcribes the captured audio. Returns the transcript text.
    func stopAndTranscribe() async throws -> String
    /// Stops recording and throws the captured audio away. Must not transcribe (or download
    /// a model): it runs on abort paths that only need the mic released promptly.
    func stopAndDiscard() async
    /// The meter the take in progress writes as buffers arrive; nil while nothing records.
    func levelMeter() async -> LevelMeter?
    /// Emits partial transcription text as the recorder receives confidence-rising guesses.
    /// May emit nothing for non-streaming backends.
    func partials() async -> AsyncStream<String>
}

public extension DictationRecorder {
    func start(configuration: DictationPipelineConfiguration) async throws {
        try await start()
    }
    func stopCapture() async throws -> DictationTake {
        DictationTake(finalize: { try await self.stopAndTranscribe() })
    }
    func stopAndDiscard() async {
        _ = try? await stopAndTranscribe()
    }
    func levelMeter() async -> LevelMeter? { nil }
    func partials() async -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}
