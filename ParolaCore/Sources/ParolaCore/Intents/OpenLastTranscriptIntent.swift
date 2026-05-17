import AppIntents
import Foundation

public enum ParolaIntentError: LocalizedError {
    case noTranscripts

    public var errorDescription: String? {
        switch self {
        case .noTranscripts:
            return "There's nothing in your library yet."
        }
    }
}

public extension Notification.Name {
    static let parolaOpenEntry = Notification.Name("com.parola.openEntry")
}

public struct OpenLastTranscriptIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Last Transcript"
    public static let description = IntentDescription("Opens your most recent transcript in Parola.")
    public static let openAppWhenRun: Bool = true

    public init() {}

    public func perform() async throws -> some IntentResult {
        let store = LibraryStore.shared
        let entries = await store.list()
        guard let latest = entries.first else {
            throw ParolaIntentError.noTranscripts
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .parolaOpenEntry,
                object: nil,
                userInfo: ["id": latest.id]
            )
        }
        return .result()
    }
}
