import Foundation

/// Everything a destination may put in a note, rendered once so every destination that runs for
/// the same entry sends the same bytes.
public struct DeliveryPayload: Codable, Sendable, Equatable {
    public var entryID: LibraryEntry.ID
    public var title: String
    public var aiTitle: String?
    public var shortSummary: String?
    public var createdAt: Date
    public var duration: Double?
    public var language: String
    public var modelName: String
    public var sourceURL: URL?
    public var sourceAppBundleID: String?
    public var speakers: [String]
    public var labels: [String]
    public var category: EntryCategory
    public var transcript: Transcript
    public var summary: Summary?
    public var favorites: [Int]
    public var markdown: String

    public init(
        entryID: LibraryEntry.ID,
        title: String,
        aiTitle: String? = nil,
        shortSummary: String? = nil,
        createdAt: Date,
        duration: Double? = nil,
        language: String,
        modelName: String,
        sourceURL: URL? = nil,
        sourceAppBundleID: String? = nil,
        speakers: [String] = [],
        labels: [String] = [],
        category: EntryCategory = .transcription,
        transcript: Transcript,
        summary: Summary? = nil,
        favorites: [Int] = [],
        markdown: String
    ) {
        self.entryID = entryID
        self.title = title
        self.aiTitle = aiTitle
        self.shortSummary = shortSummary
        self.createdAt = createdAt
        self.duration = duration
        self.language = language
        self.modelName = modelName
        self.sourceURL = sourceURL
        self.sourceAppBundleID = sourceAppBundleID
        self.speakers = speakers
        self.labels = labels
        self.category = category
        self.transcript = transcript
        self.summary = summary
        self.favorites = favorites
        self.markdown = markdown
    }

    /// The payload for a library entry. The Markdown comes from the standard `.md` export with
    /// speaker labels on, so a note reads the way an exported transcript does.
    public init(entry: LibraryEntry, document: ParolaDocument) throws {
        var spec = ExportSpec.standard(for: .md)
        spec.options.speakers = true
        spec.options.documentTitle = entry.title
        let markdown = try Exporters.exporter(for: spec).renderText(document.transcript)
        self.init(
            entryID: entry.id,
            title: entry.title,
            aiTitle: entry.aiTitle,
            shortSummary: entry.shortSummary,
            createdAt: entry.createdAt,
            duration: entry.durationSeconds ?? document.transcript.durationSeconds,
            language: entry.language,
            modelName: entry.modelName,
            sourceURL: document.transcript.sourceURL,
            sourceAppBundleID: entry.sourceAppBundleID,
            speakers: document.transcript.uniqueSpeakers,
            labels: entry.labels,
            category: entry.category,
            transcript: document.transcript,
            summary: document.transcript.summary,
            favorites: entry.favoriteSegments.sorted(),
            markdown: markdown
        )
    }

    /// The starred segments, in transcript order.
    public var favoriteSegments: [TranscriptSegment] {
        let starred = Set(favorites)
        return transcript.segments.filter { starred.contains($0.id) }
    }
}

/// Why there is no payload to build, now or on any later retry.
public enum DeliveryPayloadError: Error, LocalizedError, Equatable {
    case entryGone(LibraryEntry.ID)

    public var errorDescription: String? {
        switch self {
        case .entryGone: return "That transcript was deleted, so there is nothing to send."
        }
    }
}

public extension DeliveryPayload {
    /// The payload for a library entry. One in Recently Deleted, or purged, throws `DeliveryPayloadError.entryGone`.
    static func load(_ entryID: LibraryEntry.ID, from library: LibraryStore) async throws -> DeliveryPayload {
        let loaded: LoadedEntry
        do {
            loaded = try await library.load(entryID)
        } catch let error as LibraryStore.LibraryError {
            guard case .notFound = error else { throw error }
            throw DeliveryPayloadError.entryGone(entryID)
        }
        guard loaded.entry.deletedAt == nil else { throw DeliveryPayloadError.entryGone(entryID) }
        return try DeliveryPayload(entry: loaded.entry, document: loaded.document)
    }
}
