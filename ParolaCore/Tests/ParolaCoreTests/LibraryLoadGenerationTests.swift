import Testing
import Foundation
import os
@testable import ParolaCore

@Suite("LibraryStore load generations", .serialized, .tags(.fileSystem))
struct LibraryLoadGenerationTests {
    private final class ParkFirstDecode: Sendable {
        private let isFirst = OSAllocatedUnfairLock(initialState: true)
        private let release = DispatchSemaphore(value: 0)
        private let decodes = OSAllocatedUnfairLock(initialState: 0)
        let parked: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation

        init() { (parked, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1)) }

        var decodeCount: Int { decodes.withLock { $0 } }

        var hook: @Sendable () -> Void {
            { [self] in
                decodes.withLock { $0 += 1 }
                guard isFirst.withLock({ let was = $0; $0 = false; return was }) else { return }
                signal.yield()
                release.wait()
            }
        }

        func letGo() { release.signal() }
    }

    private func makeStore(didDecodeDocument: (@Sendable () -> Void)? = nil) throws -> (LibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-load-generation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = LibraryStore(
            storeAt: tmp, extraIndexer: nil,
            seams: LibraryStore.TestSeams(didDecodeDocument: didDecodeDocument)
        )
        return (store, tmp)
    }

    private func transcript(_ text: String, duration: Double? = nil) -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
            language: "en",
            modelName: "tiny",
            durationSeconds: duration
        )
    }

    @Test("a write to another entry while this one decodes doesn't make it decode again")
    func otherEntryWritesDoNotRetry() async throws {
        let gate = ParkFirstDecode()
        let (store, tmp) = try makeStore(didDecodeDocument: gate.hook)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let first = try await store.add(transcript: transcript("first"), audioSource: nil)
        let second = try await store.add(transcript: transcript("second"), audioSource: nil)
        await store.dropCaches()

        let loading = Task { try await store.load(first.id) }
        var arrivals = gate.parked.makeAsyncIterator()
        _ = await arrivals.next()
        try await store.renameEntry(second.id, to: "Renamed")
        gate.letGo()
        _ = try await loading.value

        #expect(gate.decodeCount == 1)
    }

    @Test("a write to the entry being decoded still sends the decode round again")
    func ownWritesRetry() async throws {
        let gate = ParkFirstDecode()
        let (store, tmp) = try makeStore(didDecodeDocument: gate.hook)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = try await store.add(transcript: transcript("before"), audioSource: nil)
        await store.dropCaches()

        let loading = Task { try await store.load(entry.id) }
        var arrivals = gate.parked.makeAsyncIterator()
        _ = await arrivals.next()
        try await store.updateTranscript(transcript("after"), for: entry.id)
        gate.letGo()
        let loaded = try await loading.value

        #expect(gate.decodeCount == 2)
        #expect(loaded.document.transcript.segments.first?.text == "after")
    }

    @Test("a load carries the length the manifest measured, not the one transcript.json stored")
    func loadAppliesTheManifestDuration() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = try await store.add(transcript: transcript("timed", duration: 100), audioSource: nil)
        try await store.setDurationSeconds(12.5, for: entry.id)
        await store.dropCaches()

        let loaded = try await store.load(entry.id)

        #expect(loaded.document.transcript.durationSeconds == 12.5)
        #expect(loaded.document.manifest.durationSeconds == 12.5)
    }

    @Test("a cached load carries the manifest duration a later correction wrote")
    func cachedLoadFollowsADurationCorrection() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = try await store.add(transcript: transcript("timed", duration: 100), audioSource: nil)
        _ = try await store.load(entry.id)
        try await store.setDurationSeconds(12.5, for: entry.id)

        let loaded = try await store.load(entry.id)

        #expect(loaded.document.transcript.durationSeconds == 12.5)
    }
}
