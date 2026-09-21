import Foundation
import Testing
@testable import ParolaCore
import ParolaTestSupport

@Suite("Delivery receipts in the manifest", .tags(.fileSystem))
struct DeliveryManifestTests {

    private func receipt(_ name: String, at path: String) -> DeliveryReceipt {
        DeliveryReceipt(
            destinationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            destinationName: name,
            deliveredAt: Date(timeIntervalSince1970: 1_780_000_000),
            location: URL(fileURLWithPath: path)
        )
    }

    private func makeStore() throws -> LibraryStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-delivery-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return LibraryStore(libraryURL: tmp, extraIndexer: nil)
    }

    @Test("a manifest written before deliveries existed decodes with none")
    func legacyDecode() throws {
        let json = """
        {"version": 2, "createdAt": "2026-05-18T00:00:00Z", "originalAudioName": "x.mp3",
         "modelName": "m", "language": "en", "category": "transcription", "source": "file"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))
        #expect(manifest.deliveries.isEmpty)
    }

    @Test("an empty list stays out of the written manifest")
    func emptyListIsOmitted() throws {
        var manifest = ParolaDocument.Manifest(originalAudioName: "x.mp3", modelName: "m", language: "it")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(!String(decoding: try encoder.encode(manifest), as: UTF8.self).contains("deliveries"))

        manifest.deliveries = [receipt("Vault", at: "/tmp/vault/Note.md")]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(ParolaDocument.Manifest.self, from: try encoder.encode(manifest))
        #expect(round.deliveries == manifest.deliveries)
    }

    @Test("appendDelivery lands on the entry and accumulates")
    func appendWritesThroughTheStore() async throws {
        let store = try makeStore()
        let entry = try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ciao")],
                language: "it",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )

        try await store.appendDelivery(receipt("Vault", at: "/tmp/vault/One.md"), for: entry.id)
        try await store.appendDelivery(receipt("Vault", at: "/tmp/vault/Two.md"), for: entry.id)

        let reloaded = try await store.load(entry.id)
        #expect(reloaded.entry.deliveries.count == 2)
        #expect(reloaded.entry.deliveries.map(\.location?.lastPathComponent) == ["One.md", "Two.md"])
        #expect(reloaded.entry.deliveries.first?.destinationName == "Vault")
    }

    @Test("appending to an entry that isn't there reports it")
    func appendToMissingEntry() async throws {
        let store = try makeStore()
        await #expect(throws: LibraryStore.LibraryError.self) {
            try await store.appendDelivery(receipt("Vault", at: "/tmp/x.md"), for: "nope")
        }
    }
}

@Suite("Send To feature gate")
struct DeliveryFeatureGateTests {
    private func makeManaged(_ dict: [String: Any]?) -> ManagedConfiguration {
        let store = temporaryDefaults("delivery-gate-tests-")
        if let dict { store.set(dict, forKey: "test.managed") }
        return ManagedConfiguration(storage: store, domainKey: "test.managed")
    }

    @Test("destinations ship enabled")
    func enabledByDefault() {
        #expect(FeatureSet.all.isEnabled(.destinations))
        #expect(FeatureSet.resolve(managed: makeManaged(nil)).isEnabled(.destinations))
    }

    @Test("the managed switch turns it off")
    func managedDisable() {
        let managed = makeManaged(["disableDestinations": true])
        #expect(managed.disableDestinations)
        #expect(managed.isManaged(.disableDestinations))
        #expect(!FeatureSet.resolve(managed: managed).isEnabled(.destinations))
    }

    @Test("an allowlist without it leaves it out")
    func allowlistOmission() {
        let set = FeatureSet.resolve(managed: makeManaged(["enabledFeatures": ["dictation"]]))
        #expect(!set.isEnabled(.destinations))
    }

    @Test("the feature has a name for the diagnostics header")
    func displayName() {
        #expect(!ParolaFeature.destinations.displayName.isEmpty)
    }
}
