import Foundation

/// Hooks the app installs at launch so App Intents can run in-app work (stop a recording, transcribe a file, open the latest entry) and return the resulting transcript text. Intents that find a hook missing fail with a plain "not available" error, except Open Last Transcript, which falls back to reading the library itself.
@MainActor
public enum IntentPerformers {
    public static var stopRecording: (@MainActor () async throws -> String)?
    public static var transcribeFile: (@MainActor (URL) async throws -> String)?
    public static var openLatest: (@MainActor () async throws -> String)?
}
