import AppIntents
import Foundation

public extension Notification.Name {
    static let parolaStartDictation = Notification.Name("com.parola.startDictation")
    static let parolaStopDictation = Notification.Name("com.parola.stopDictation")
}

public struct StartDictationIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Dictation"
    public static let description = IntentDescription("Starts a push-to-talk dictation session in Parola.")
    public static let openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .parolaStartDictation, object: nil)
        }
        return .result()
    }
}

public struct StopDictationIntent: AppIntent {
    public static let title: LocalizedStringResource = "Stop Dictation"
    public static let description = IntentDescription("Stops the current dictation session in Parola and inserts the result.")
    public static let openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .parolaStopDictation, object: nil)
        }
        return .result()
    }
}
