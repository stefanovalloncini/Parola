import Testing
import Foundation
import os
@testable import ParolaCore

@Suite("LibraryStore load cache", .tags(.fileSystem))
struct LibraryLoadCacheTests {
    private func makeStore(
        didDecodeDocument: (@Sendable () -> Void)? = nil
    ) throws -> (LibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-load-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = LibraryStore(
            libraryURL: tmp, extraIndexer: nil, didDecodeDocument: didDecodeDocument
        )
        return (store, tmp)
    }

    private func makeTranscript(_ text: String, segments count: Int = 1) -> Transcript {
        Transcript(
            segments: (0..<count).map {
                TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 0.5, text: text)
            },
            language: "en",
            modelName: "tiny"
        )
    }

    /// Rewrites transcript.json behind the actor's back, so a load still answering with the old text
    /// can only have taken it from the cache.
    private func rewriteOnDisk(_ entry: LibraryEntry, text: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(makeTranscript(text))
        try data.write(to: entry.bundleURL.appendingPathComponent("transcript.json"), options: .atomic)
    }

    private func firstText(_ loaded: LoadedEntry) -> String? {
        loaded.document.transcript.segments.first?.text
    }

    @Test("a repeat load of the same entry answers from the cache")
    func repeatLoadSkipsDisk() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = try await store.add(transcript: makeTranscript("original"), audioSource: nil)
        #expect(firstText(try await store.load(entry.id)) == "original")

        try rewriteOnDisk(entry, text: "on disk")

        #expect(firstText(try await store.load(entry.id)) == "original")
    }

    @Test("alternating between two entries re-reads neither")
    func alternatingLoadsStayCached() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = try await store.add(transcript: makeTranscript("a"), audioSource: nil)
        let b = try await store.add(transcript: makeTranscript("b"), audioSource: nil)
        _ = try await store.load(a.id)
        _ = try await store.load(b.id)

        try rewriteOnDisk(a, text: "a on disk")
        try rewriteOnDisk(b, text: "b on disk")

        #expect(firstText(try await store.load(a.id)) == "a")
        #expect(firstText(try await store.load(b.id)) == "b")
    }

    @Test("a fourth entry evicts the least recently loaded one")
    func fourthLoadEvictsTheOldest() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var entries: [LibraryEntry] = []
        for i in 0..<4 {
            entries.append(try await store.add(transcript: makeTranscript("entry \(i)"), audioSource: nil))
        }
        for entry in entries {
            _ = try await store.load(entry.id)
        }
        for entry in entries {
            try rewriteOnDisk(entry, text: "\(entry.id) on disk")
        }

        #expect(firstText(try await store.load(entries[0].id)) == "\(entries[0].id) on disk")
        #expect(firstText(try await store.load(entries[3].id)) == "entry 3")
    }

    @Test("updateTranscript drops the cached copy of that entry and no other")
    func updateTranscriptInvalidatesOneSlot() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = try await store.add(transcript: makeTranscript("a"), audioSource: nil)
        let b = try await store.add(transcript: makeTranscript("b"), audioSource: nil)
        _ = try await store.load(a.id)
        _ = try await store.load(b.id)

        try await store.updateTranscript(makeTranscript("a edited"), for: a.id)
        try rewriteOnDisk(b, text: "b on disk")

        #expect(firstText(try await store.load(a.id)) == "a edited")
        #expect(firstText(try await store.load(b.id)) == "b")
    }

    @Test("a manifest edit refreshes the cached entry without re-reading the transcript")
    func manifestEditPatchesTheCachedEntry() async throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = try await store.add(transcript: makeTranscript("original"), audioSource: nil)
        _ = try await store.load(entry.id)
        try rewriteOnDisk(entry, text: "on disk")

        try await store.renameEntry(entry.id, to: "Standup")

        let loaded = try await store.load(entry.id)
        #expect(loaded.entry.title == "Standup")
        #expect(firstText(loaded) == "original")
    }

    /// Parks decodes that have read the bundle but not yet answered, so a mutation can be made to
    /// land inside one instead of raced against it.
    private final class DecodeGate: Sendable {
        private struct Arming: Sendable {
            let release: DispatchSemaphore
            var remaining: Int
            var parked: Int
        }

        private let state = OSAllocatedUnfairLock<Arming?>(initialState: nil)

        var hook: @Sendable () -> Void {
            { [state] in
                let release: DispatchSemaphore? = state.withLock { current in
                    guard var arming = current, arming.remaining > 0 else { return nil }
                    arming.remaining -= 1
                    arming.parked += 1
                    current = arming
                    return arming.release
                }
                release?.wait()
            }
        }

        /// Runs `body` once `count` decodes are parked, then lets them all answer.
        func holding(_ count: Int, _ body: () async throws -> Void) async rethrows {
            let release = DispatchSemaphore(value: 0)
            state.withLock { $0 = Arming(release: release, remaining: count, parked: 0) }
            defer {
                state.withLock { $0 = nil }
                for _ in 0..<count { release.signal() }
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while state.withLock({ $0?.parked ?? count }) < count {
                if ContinuousClock.now > deadline {
                    Issue.record("the decodes never reached the gate")
                    break
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            try await body()
        }
    }

    @Test("a load in flight when updateTranscript lands never answers with the pre-update transcript")
    func loadRacingUpdateSeesTheUpdate() async throws {
        let gate = DecodeGate()
        let (store, tmp) = try makeStore(didDecodeDocument: gate.hook)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = try await store.add(transcript: makeTranscript("original 0"), audioSource: nil)

        for i in 0..<8 {
            if i > 0 {
                try await store.updateTranscript(makeTranscript("original \(i)"), for: entry.id)
            }
            let loading = Task { try await store.load(entry.id) }
            try await gate.holding(1) {
                try await store.updateTranscript(makeTranscript("edited \(i)"), for: entry.id)
            }

            #expect(firstText(try await loading.value) == "edited \(i)")
            #expect(firstText(try await store.load(entry.id)) == "edited \(i)")
        }
    }

    @Test("two concurrent loads of the same entry agree on one whole version")
    func concurrentLoadsAgree() async throws {
        let gate = DecodeGate()
        let (store, tmp) = try makeStore(didDecodeDocument: gate.hook)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = try await store.add(transcript: makeTranscript("original 0", segments: 8), audioSource: nil)

        for i in 0..<8 {
            if i > 0 {
                try await store.updateTranscript(makeTranscript("original \(i)", segments: 8), for: entry.id)
            }
            let first = Task { try await store.load(entry.id) }
            let second = Task { try await store.load(entry.id) }
            try await gate.holding(2) {
                try await store.updateTranscript(makeTranscript("edited \(i)", segments: 8), for: entry.id)
            }

            let firstTexts = Set(try await first.value.document.transcript.segments.map(\.text))
            let secondTexts = Set(try await second.value.document.transcript.segments.map(\.text))
            #expect(firstTexts.count == 1, "a load blended two versions of the transcript")
            #expect(secondTexts.count == 1, "a load blended two versions of the transcript")
            #expect(firstTexts == secondTexts, "concurrent loads of one entry disagreed")
            #expect(firstTexts.first == "original \(i)" || firstTexts.first == "edited \(i)")
            #expect(firstText(try await store.load(entry.id)) == "edited \(i)")
        }
    }
}
