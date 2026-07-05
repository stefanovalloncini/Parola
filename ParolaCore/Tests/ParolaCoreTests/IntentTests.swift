import Testing
import Foundation
import AppIntents
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

    private func makeTranscript(text: String = "hi") -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 0.5, text: text)],
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

    @Test("Darwin dictation signal delivers the stop name")
    func dictationStopSignalRoundTrip() async {
        let delivered = SignalGate()
        let subscription = DictationSignal.subscribe { name in
            if name == DictationSignal.stopName { delivered.fulfill() }
        }
        defer { subscription.cancel() }

        await confirmation("received stop") { received in
            DictationSignal.stop()
            await delivered.wait()
            received()
        }
    }

    private func confirmIntentPosts(
        _ name: Notification.Name,
        when action: () async throws -> Void
    ) async throws {
        try await confirmation("posted \(name.rawValue)") { posted in
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { _ in posted() }
            defer { NotificationCenter.default.removeObserver(token) }
            try await action()
        }
    }

    @Test("StartRecordingIntent posts the start-recording notification")
    func startRecordingIntentPostsNotification() async throws {
        try await confirmIntentPosts(.parolaStartRecording) {
            _ = try await StartRecordingIntent().perform()
        }
    }

    @Test("SummarizeLastTranscriptIntent posts the summarize notification")
    func summarizeIntentPostsNotification() async throws {
        try await confirmIntentPosts(.parolaSummarizeLast) {
            _ = try await SummarizeLastTranscriptIntent().perform()
        }
    }

    @Test("StartDictationIntent posts the start-dictation notification")
    func startDictationIntentPostsNotification() async throws {
        try await confirmIntentPosts(.parolaStartDictation) {
            _ = try await StartDictationIntent().perform()
        }
    }

    @Test("StopDictationIntent posts the stop-dictation notification")
    func stopDictationIntentPostsNotification() async throws {
        try await confirmIntentPosts(.parolaStopDictation) {
            _ = try await StopDictationIntent().perform()
        }
    }

    @Test("latest transcript lookup returns the newest entry's text")
    func latestTranscriptTextNewest() async throws {
        let store = try makeTempStore()
        let older = try await store.add(transcript: makeTranscript(text: "old words"), audioSource: nil)
        try ParolaDocument.updateManifest(at: older.bundleURL) {
            $0.createdAt = Date(timeIntervalSinceNow: -3600)
        }
        let newer = try await store.add(transcript: makeTranscript(text: "new words"), audioSource: nil)

        let latest = try await IntentTranscriptLookup.latestTranscriptText(in: store)

        #expect(latest.entryID == newer.id)
        #expect(latest.text == "new words")
    }

    @Test("latest transcript lookup throws on an empty library")
    func latestTranscriptTextEmpty() async throws {
        let store = try makeTempStore()
        await #expect(throws: ParolaIntentError.noTranscripts) {
            _ = try await IntentTranscriptLookup.latestTranscriptText(in: store)
        }
    }

    @Test("latest transcript lookup sees entries written by another store instance")
    func latestTranscriptTextSeesForeignWrites() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-intent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let reader = LibraryStore(libraryURL: tmp, extraIndexer: nil)
        #expect(await reader.list().isEmpty)

        let writer = LibraryStore(libraryURL: tmp, extraIndexer: nil)
        _ = try await writer.add(transcript: makeTranscript(text: "fresh words"), audioSource: nil)

        let latest = try await IntentTranscriptLookup.latestTranscriptText(in: reader)
        #expect(latest.text == "fresh words")
    }

    @Test("materialize passes a URL-backed IntentFile through")
    func materializeURLBacked() throws {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-intent-src-\(UUID().uuidString).wav")
        try Data("RIFFfake".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let out = try TranscribeFileIntent.materialize(IntentFile(fileURL: src))
        #expect(out.url == src)
    }

    @Test("materialize writes a data-backed IntentFile to a temp path")
    func materializeDataBacked() throws {
        let file = IntentFile(data: Data("abc".utf8), filename: "clip.wav")

        let out = try TranscribeFileIntent.materialize(file)
        defer { try? FileManager.default.removeItem(at: out.url.deletingLastPathComponent()) }

        #expect(out.scoped == false)
        #expect(out.url.lastPathComponent == "clip.wav")
        #expect(try String(contentsOf: out.url, encoding: .utf8) == "abc")
    }
}

@MainActor
@Suite("Intent performers", .serialized)
struct IntentPerformerTests {
    @Test("StopRecordingIntent throws when no performer is installed")
    func stopUnavailable() async {
        IntentPerformers.stopRecording = nil
        await #expect(throws: ParolaIntentError.unavailable) {
            _ = try await StopRecordingIntent().perform()
        }
    }

    @Test("StopRecordingIntent returns the performer's transcript text")
    func stopReturnsPerformerText() async throws {
        defer { IntentPerformers.stopRecording = nil }
        IntentPerformers.stopRecording = { "final words" }

        let result = try await StopRecordingIntent().perform()

        let value = Mirror(reflecting: result).children
            .first { $0.label == "value" }
            .flatMap { $0.value as? String }
        #expect(value == "final words")
    }

    @Test("TranscribeFileIntent throws when no performer is installed")
    func transcribeUnavailable() async {
        IntentPerformers.transcribeFile = nil
        let src = URL(fileURLWithPath: "/tmp/parola-intent-nope-\(UUID().uuidString).wav")
        await #expect(throws: ParolaIntentError.unavailable) {
            _ = try await TranscribeFileIntent(file: IntentFile(fileURL: src)).perform()
        }
    }

    @Test("TranscribeFileIntent hands the picked file URL to the performer")
    func transcribeCallsPerformer() async throws {
        defer { IntentPerformers.transcribeFile = nil }
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-intent-perform-\(UUID().uuidString).wav")
        try Data("RIFFfake".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let received = URLBox()
        IntentPerformers.transcribeFile = { url in
            received.url = url
            return "transcribed"
        }

        _ = try await TranscribeFileIntent(file: IntentFile(fileURL: src)).perform()
        #expect(received.url == src)
    }

    @MainActor
    private final class URLBox {
        var url: URL?
    }
}
