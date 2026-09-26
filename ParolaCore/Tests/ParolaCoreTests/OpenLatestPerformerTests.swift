import Testing
import Foundation
import os
@testable import ParolaCore

@MainActor
@Suite("Open latest performer", .serialized)
struct OpenLatestPerformerTests {
    @Test("OpenLastTranscriptIntent answers through the app's performer, not a store of its own")
    func openLastCallsPerformer() async throws {
        defer { IntentPerformers.openLatest = nil }
        IntentPerformers.openLatest = { "the newest words" }

        let result = try await OpenLastTranscriptIntent().perform()

        let value = Mirror(reflecting: result).children
            .first { $0.label == "value" }
            .flatMap { $0.value as? String }
        #expect(value == "the newest words")
    }

    @Test("the app's own store keeps its caches when it answers Open Last Transcript")
    func lookupWithoutRescanKeepsTheCaches() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-open-latest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let decodes = OSAllocatedUnfairLock(initialState: 0)
        let store = LibraryStore(
            storeAt: url, extraIndexer: nil,
            seams: LibraryStore.TestSeams(didDecodeDocument: { decodes.withLock { $0 += 1 } })
        )
        _ = try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "the newest words")],
                language: "en",
                modelName: "tiny"
            ),
            audioSource: nil
        )

        _ = try await IntentTranscriptLookup.latestTranscriptText(in: store, rescan: false)
        let latest = try await IntentTranscriptLookup.latestTranscriptText(in: store, rescan: false)
        #expect(latest.text == "the newest words")
        #expect(decodes.withLock { $0 } == 0, "the add left the entry in the store's cache")

        _ = try await IntentTranscriptLookup.latestTranscriptText(in: store, rescan: true)
        #expect(decodes.withLock { $0 } == 1)
    }
}
