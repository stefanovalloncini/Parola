import Foundation
import Testing
@testable import ParolaCore

@Suite("Voice print store")
struct VoicePrintStoreTests {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-voiceprints-\(UUID().uuidString).json")
    }

    @Test("enroll adds a new print under the given name")
    func enrollNew() async {
        let store = VoicePrintStore(storageURL: makeURL())
        let print = await store.enroll(name: "Alice", embedding: [1, 0, 0])
        #expect(print.name == "Alice")
        let all = await store.allPrints
        #expect(all.count == 1)
        #expect(all[0].sampleCount == 1)
    }

    @Test("enroll for an existing name updates the centroid and sample count")
    func enrollExisting() async {
        let store = VoicePrintStore(storageURL: makeURL())
        _ = await store.enroll(name: "Alice", embedding: [1, 0, 0])
        let updated = await store.enroll(name: "Alice", embedding: [0, 1, 0])
        #expect(updated.sampleCount == 2)
        #expect(updated.embedding == [0.5, 0.5, 0])
    }

    @Test("enroll names are matched case-insensitively after trimming")
    func enrollNormalization() async {
        let store = VoicePrintStore(storageURL: makeURL())
        _ = await store.enroll(name: "Alice", embedding: [1, 0, 0])
        let again = await store.enroll(name: "  alice  ", embedding: [0, 1, 0])
        #expect(again.sampleCount == 2)
    }

    @Test("suggest returns the closest stored print above the threshold")
    func suggestMatches() async {
        let store = VoicePrintStore(storageURL: makeURL())
        _ = await store.enroll(name: "Alice", embedding: [1, 0, 0])
        _ = await store.enroll(name: "Bob", embedding: [0, 1, 0])
        let hit = await store.suggest(for: [0.95, 0.05, 0], threshold: 0.85)
        #expect(hit?.name == "Alice")
    }

    @Test("suggest returns nil when nothing clears the threshold")
    func suggestBelowThreshold() async {
        let store = VoicePrintStore(storageURL: makeURL())
        _ = await store.enroll(name: "Alice", embedding: [1, 0, 0])
        let miss = await store.suggest(for: [0, 0, 1], threshold: 0.5)
        #expect(miss == nil)
    }

    @Test("forget removes the named print")
    func forgetByName() async {
        let store = VoicePrintStore(storageURL: makeURL())
        _ = await store.enroll(name: "Alice", embedding: [1, 0, 0])
        let removed = await store.forget(name: "alice")
        #expect(removed)
        let all = await store.allPrints
        #expect(all.isEmpty)
    }

    @Test("store persists across instances")
    func persists() async {
        let url = makeURL()
        let first = VoicePrintStore(storageURL: url)
        _ = await first.enroll(name: "Alice", embedding: [1, 0, 0])
        let second = VoicePrintStore(storageURL: url)
        let prints = await second.allPrints
        #expect(prints.count == 1)
        #expect(prints[0].name == "Alice")
    }
}
