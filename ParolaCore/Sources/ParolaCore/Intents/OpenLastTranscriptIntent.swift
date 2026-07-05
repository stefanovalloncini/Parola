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

enum IntentTranscriptLookup {
    static func latestTranscriptText(in store: LibraryStore) async throws -> (entryID: String, text: String) {
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

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let latest = try await IntentTranscriptLookup.latestTranscriptText(in: LibraryStore.shared)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .parolaOpenEntry,
                object: nil,
                userInfo: ["id": latest.entryID]
            )
        }
        return .result(value: latest.text)
    }
}
