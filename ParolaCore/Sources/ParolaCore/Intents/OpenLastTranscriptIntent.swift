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

/// The newest entry's id and text. `rescan` is for a store other than the one the app writes through,
/// whose caches can't see the app's writes; the app's own store passes false and keeps its caches.
public enum IntentTranscriptLookup {
    public static func latestTranscriptText(in store: LibraryStore, rescan: Bool) async throws -> (entryID: String, text: String) {
        if rescan { await store.dropCaches() }
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
        let latest = try await IntentTranscriptLookup.latestTranscriptText(in: LibraryStore.shared, rescan: true)
        NotificationCenter.default.post(
            name: .parolaOpenEntry,
            object: nil,
            userInfo: ["id": latest.entryID]
        )
        return .result(value: latest.text)
    }
}
