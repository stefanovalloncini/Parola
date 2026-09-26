import AppIntents
import Foundation

enum ParolaIntentError: LocalizedError, Equatable {
    case noTranscripts
    case unavailable

    var errorDescription: String? {
        switch self {
        case .noTranscripts:
            return "There's nothing in your library yet."
        case .unavailable:
            return "Parola can't run this action here yet."
        }
    }
}

/// The newest entry's id and text, for an app that answers Open Last Transcript from the store it already holds.
public enum IntentTranscriptLookup {
    public static func latestTranscriptText(in store: LibraryStore) async throws -> (entryID: String, text: String) {
        // The app writes through its own LibraryStore instance, so this one must re-scan disk.
        await store.dropCaches()
        guard let latest = await store.list().first else {
            throw ParolaIntentError.noTranscripts
        }
        let loaded = try await store.load(latest.id)
        return (latest.id, loaded.document.transcript.text)
    }
}

public extension Notification.Name {
    static let parolaOpenEntry = Notification.Name("com.parola.openEntry")
}

public struct OpenLastTranscriptIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Last Transcript"
    public static let description = IntentDescription("Opens your most recent transcript in Parola and returns its text.")
    public static let openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if let openLatest = IntentPerformers.openLatest {
            return .result(value: try await openLatest())
        }
        let latest = try await IntentTranscriptLookup.latestTranscriptText(in: LibraryStore.shared)
        NotificationCenter.default.post(
            name: .parolaOpenEntry,
            object: nil,
            userInfo: ["id": latest.entryID]
        )
        return .result(value: latest.text)
    }
}
