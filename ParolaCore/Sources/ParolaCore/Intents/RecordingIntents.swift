import AppIntents
import Foundation

public extension Notification.Name {
    static let parolaStartRecording = Notification.Name("com.parola.startRecording")
    static let parolaSummarizeLast = Notification.Name("com.parola.summarizeLast")
}

public struct StartRecordingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Recording"
    public static let description = IntentDescription("Starts a microphone recording in Parola.")
    public static let openAppWhenRun: Bool = true

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .parolaStartRecording, object: nil)
        }
        return .result()
    }
}

public struct SummarizeLastTranscriptIntent: AppIntent {
    public static let title: LocalizedStringResource = "Summarize Last Transcript"
    public static let description = IntentDescription("Generates a summary for your most recent transcript in Parola.")
    public static let openAppWhenRun: Bool = true

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .parolaSummarizeLast, object: nil)
        }
        return .result()
    }
}
