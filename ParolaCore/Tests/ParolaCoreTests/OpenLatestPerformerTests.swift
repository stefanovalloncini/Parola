import Testing
import Foundation
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
}
