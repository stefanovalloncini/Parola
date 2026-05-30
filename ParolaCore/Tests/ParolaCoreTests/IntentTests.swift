import Testing
import Foundation
import os
@testable import ParolaCore

/// A one-shot async latch: `wait()` suspends until `fulfill()` is called from any thread.
private final class SignalGate: Sendable {
    private struct State {
        var fulfilled = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func fulfill() {
        let resume = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.fulfilled else { return nil }
            state.fulfilled = true
            defer { state.continuation = nil }
            return state.continuation
        }
        resume?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyFulfilled = state.withLock { state -> Bool in
                if state.fulfilled { return true }
                state.continuation = continuation
                return false
            }
            if alreadyFulfilled { continuation.resume() }
        }
    }
}

@Suite("App Intents")
struct IntentTests {
    private func makeTempStore() throws -> LibraryStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-intent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return LibraryStore(libraryURL: tmp, extraIndexer: nil)
    }

    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 0.5, text: "hi")],
            language: "en",
            modelName: "tiny"
        )
    }

    @Test("suggestedEntities returns recent library entries")
    func suggestionsReturnsRecent() async throws {
        let store = try makeTempStore()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let query = LibraryEntryEntityQuery(store: store)
        let suggestions = try await query.suggestedEntities()
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.id == entry.id)
    }

    @Test("entities(for:) resolves entries by id")
    func entitiesByID() async throws {
        let store = try makeTempStore()
        let entry = try await store.add(transcript: makeTranscript(), audioSource: nil)
        let query = LibraryEntryEntityQuery(store: store)
        let resolved = try await query.entities(for: [entry.id])
        #expect(resolved.count == 1)
        #expect(resolved.first?.id == entry.id)
        #expect(resolved.first?.title == entry.title)
    }

    @Test("suggestedEntities limits to 10 most recent")
    func suggestionsLimit() async throws {
        let store = try makeTempStore()
        for _ in 0..<12 {
            _ = try await store.add(transcript: makeTranscript(), audioSource: nil)
        }
        let query = LibraryEntryEntityQuery(store: store)
        let suggestions = try await query.suggestedEntities()
        #expect(suggestions.count == 10)
    }

    @Test("entities(for:) returns empty for unknown ids")
    func entitiesUnknown() async throws {
        let store = try makeTempStore()
        let query = LibraryEntryEntityQuery(store: store)
        let resolved = try await query.entities(for: ["nope"])
        #expect(resolved.isEmpty)
    }

    @Test("Darwin dictation signal delivers across the start/stop names")
    func dictationSignalRoundTrip() async {
        let delivered = SignalGate()
        let subscription = DictationSignal.subscribe { name in
            if name == DictationSignal.startName { delivered.fulfill() }
        }
        defer { subscription.cancel() }

        await confirmation("received start") { received in
            DictationSignal.start()
            await delivered.wait()
            received()
        }
    }
}
