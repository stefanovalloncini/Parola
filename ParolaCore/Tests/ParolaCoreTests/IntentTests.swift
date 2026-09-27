import Testing
import Foundation
import AppIntents
import os
@testable import ParolaCore

/// A one-shot async latch: `wait()` suspends until `fulfill()` is called from any thread, or until its timeout.
private final class SignalGate: Sendable {
    private struct State {
        var outcome: Bool?
        var continuation: CheckedContinuation<Bool, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func fulfill() {
        settle(true)
    }

    /// A Darwin delivery can be lost, so the wait ends after `timeout` and says whether the signal came.
    func wait(timeout: Duration = .seconds(5)) async -> Bool {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.settle(false)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            let settled = state.withLock { state -> Bool? in
                if let outcome = state.outcome { return outcome }
                state.continuation = continuation
                return nil
            }
            if let settled { continuation.resume(returning: settled) }
        }
    }

    private func settle(_ outcome: Bool) {
        let resume = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            defer { state.continuation = nil }
            return state.continuation
        }
        resume?.resume(returning: outcome)
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

    /// Darwin notifications reach every process on the Mac, so these tests signal on names no running Parola listens to.
    private func withPrivateSignalNames(_ body: (DictationSignal.Names) async throws -> Void) async rethrows {
        let id = UUID().uuidString
        let names = DictationSignal.Names(start: "com.parola.tests.\(id).start", stop: "com.parola.tests.\(id).stop")
        try await DictationSignal.$names.withValue(names) {
            try await body(names)
        }
    }

    @Test("Parola's own signal names stay the ones the intents and the app share")
    func parolaSignalNames() {
        #expect(DictationSignal.Names.parola == DictationSignal.Names(
            start: "com.parola.dictation.start", stop: "com.parola.dictation.stop"
        ))
        #expect(DictationSignal.names == .parola)
    }

    @Test("Darwin dictation signal delivers across the start/stop names")
    func dictationSignalRoundTrip() async {
        await withPrivateSignalNames { names in
            let delivered = SignalGate()
            let subscription = DictationSignal.subscribe { name in
                if name == names.start { delivered.fulfill() }
            }
            defer { subscription.cancel() }

            await confirmation("received start") { received in
                DictationSignal.start()
                if await delivered.wait() { received() }
            }
        }
    }

    @Test("Darwin dictation signal delivers the stop name")
    func dictationStopSignalRoundTrip() async {
        await withPrivateSignalNames { names in
            let delivered = SignalGate()
            let subscription = DictationSignal.subscribe { name in
                if name == names.stop { delivered.fulfill() }
            }
            defer { subscription.cancel() }

            await confirmation("received stop") { received in
                DictationSignal.stop()
                if await delivered.wait() { received() }
            }
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

    private func confirmDictationIntentSignalsOnce(
        signal: KeyPath<DictationSignal.Names, String>,
        notification: Notification.Name,
        when action: () async throws -> Void
    ) async throws {
        try await withPrivateSignalNames { names in
            let signalName = names[keyPath: signal]
            let signalled = OSAllocatedUnfairLock(initialState: false)
            let notificationPosts = OSAllocatedUnfairLock(initialState: 0)
            let subscription = DictationSignal.subscribe { name in
                if name == signalName { signalled.withLock { $0 = true } }
            }
            let token = NotificationCenter.default.addObserver(
                forName: notification, object: nil, queue: nil
            ) { _ in notificationPosts.withLock { $0 += 1 } }
            defer {
                subscription.cancel()
                NotificationCenter.default.removeObserver(token)
            }
            try await action()
            var spins = 0
            while !signalled.withLock({ $0 }), spins < 300 {
                try? await Task.sleep(for: .milliseconds(10))
                spins += 1
            }
            #expect(signalled.withLock { $0 }, "the Darwin signal is the one delivery channel")
            #expect(notificationPosts.withLock { $0 } == 0, "a NotificationCenter post would double-fire the in-process subscriber")
        }
    }

    @Test("StartDictationIntent signals once, over Darwin only")
    func startDictationIntentSignalsOnce() async throws {
        try await confirmDictationIntentSignalsOnce(
            signal: \.start,
            notification: .parolaStartDictation
        ) {
            _ = try await StartDictationIntent().perform()
        }
    }

    @Test("StopDictationIntent signals once, over Darwin only")
    func stopDictationIntentSignalsOnce() async throws {
        try await confirmDictationIntentSignalsOnce(
            signal: \.stop,
            notification: .parolaStopDictation
        ) {
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

        let latest = try await IntentTranscriptLookup.latestTranscriptText(in: store, rescan: true)

        #expect(latest.entryID == newer.id)
        #expect(latest.text == "new words")
    }

    @Test("latest transcript lookup throws on an empty library")
    func latestTranscriptTextEmpty() async throws {
        let store = try makeTempStore()
        await #expect(throws: ParolaIntentError.noTranscripts) {
            _ = try await IntentTranscriptLookup.latestTranscriptText(in: store, rescan: true)
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

        let latest = try await IntentTranscriptLookup.latestTranscriptText(in: reader, rescan: true)
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
