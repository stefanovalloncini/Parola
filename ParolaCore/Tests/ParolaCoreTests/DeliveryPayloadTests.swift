import Foundation
import Testing
@testable import ParolaCore

@Suite("Delivery payload")
struct DeliveryPayloadTests {

    static func transcript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 3.5, text: "Welcome back.", speaker: "Ada"),
                TranscriptSegment(id: 1, start: 3.5, end: 9, text: "Glad to be here.", speaker: "Grace"),
                TranscriptSegment(id: 2, start: 9, end: 14, text: "Tell me how it went.", speaker: "Ada"),
            ],
            language: "en",
            modelName: "openai_whisper-tiny",
            sourceURL: URL(fileURLWithPath: "/tmp/parola-delivery/interview.m4a"),
            durationSeconds: 134
        )
    }

    private func makeLibrary() throws -> LibraryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-delivery-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return LibraryStore(libraryURL: url, extraIndexer: nil)
    }

    @Test("a library entry loads as a payload; a trashed or purged one is gone for good")
    func loadRefusesDeletedEntries() async throws {
        let library = try makeLibrary()
        let entry = try await library.add(transcript: Self.transcript(), audioSource: nil)

        #expect(try await DeliveryPayload.load(entry.id, from: library).transcript.text == Self.transcript().text)

        try await library.delete(entry.id)
        await #expect(throws: DeliveryPayloadError.entryGone(entry.id)) {
            _ = try await DeliveryPayload.load(entry.id, from: library)
        }

        try await library.purge(entry.id)
        await #expect(throws: DeliveryPayloadError.entryGone(entry.id)) {
            _ = try await DeliveryPayload.load(entry.id, from: library)
        }
    }

    static func payload(
        title: String = "Interview",
        aiTitle: String? = nil,
        favorites: [Int] = [],
        summary: Summary? = nil,
        labels: [String] = []
    ) -> DeliveryPayload {
        DeliveryPayload(
            entryID: "entry-1",
            title: title,
            aiTitle: aiTitle,
            shortSummary: "Two people talk about a release.",
            createdAt: Date(timeIntervalSince1970: 1_780_272_000),
            duration: 134,
            language: "en",
            modelName: "openai_whisper-tiny",
            sourceURL: URL(fileURLWithPath: "/tmp/parola-delivery/interview.m4a"),
            speakers: ["Ada", "Grace"],
            labels: labels,
            category: .meeting,
            transcript: transcript(),
            summary: summary,
            favorites: favorites,
            markdown: "# Interview\n"
        )
    }

    @Test("the payload for an entry renders the Markdown export with speakers")
    func builtFromAnEntry() throws {
        var manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_780_272_000),
            originalAudioName: "interview.m4a",
            modelName: "openai_whisper-tiny",
            language: "en",
            category: .meeting,
            labels: ["work"],
            favoriteSegments: [2, 1],
            durationSeconds: 134,
            aiTitle: "Release chat",
            shortSummary: "Two people talk about a release."
        )
        manifest.title = "Interview"
        let entry = LibraryEntry(
            id: "entry-1",
            bundleURL: URL(fileURLWithPath: "/tmp/entry-1.parola"),
            manifest: manifest
        )
        let document = ParolaDocument(transcript: Self.transcript(), audioURL: nil, manifest: manifest)

        let payload = try DeliveryPayload(entry: entry, document: document)

        #expect(payload.entryID == "entry-1")
        #expect(payload.title == "Interview")
        #expect(payload.aiTitle == "Release chat")
        #expect(payload.category == .meeting)
        #expect(payload.labels == ["work"])
        #expect(payload.speakers == ["Ada", "Grace"])
        #expect(payload.duration == 134)
        #expect(payload.favorites == [1, 2])
        #expect(payload.markdown.contains("**Ada:** Welcome back."))
        #expect(payload.markdown.hasPrefix("# Interview\n"))
    }

    @Test("favoriteSegments lists the starred segments in transcript order")
    func favoritesInOrder() {
        let payload = Self.payload(favorites: [2, 0])
        #expect(payload.favoriteSegments.map(\.id) == [0, 2])
        #expect(payload.favoriteSegments.map(\.text) == ["Welcome back.", "Tell me how it went."])
    }

    @Test("a payload round-trips through JSON")
    func roundTrips() throws {
        let payload = Self.payload(favorites: [1], summary: Summary(text: "A release chat."))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DeliveryPayload.self, from: try encoder.encode(payload))
        #expect(restored == payload)
    }
}
