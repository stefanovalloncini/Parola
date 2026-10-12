import Foundation
import os
import Testing
import ParolaTestSupport
@testable import ParolaCore

@Suite("Library logging", .serialized, .tags(.fileSystem))
struct LibraryLoggingTests {
    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        try await ParolaLog.withSink(sink) { try await body(sink) }
    }

    private func records(
        _ sink: CapturingDiagnosticsSink, _ category: LogCategory, message: String
    ) -> [LogRecord] {
        sink.records.filter { $0.category == category && $0.message.rendered == message }
    }

    private func waitForRecord(
        _ sink: CapturingDiagnosticsSink, _ category: LogCategory, message: String
    ) async -> LogRecord? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let record = records(sink, category, message: message).first { return record }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func makeLibraryURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-library-logging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-library-logging-\(UUID().uuidString).wav")
        try Data("RIFFfakeaudio".utf8).write(to: url)
        return url
    }

    private func makeTranscript(_ text: String = "sprint planning") -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 0.5, text: text)],
            language: "en",
            modelName: "tiny"
        )
    }

    private func setPermissions(_ mode: Int, on url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // .logFacade: `list()` logs this one from a GCD hop, which no scope reaches, so it needs the installed sink.
    @Test("a library folder that cannot be listed is logged, and never by its path", .logFacade)
    func unreadableLibraryFolder() async throws {
        let sink = CapturingDiagnosticsSink()
        ParolaLog.install(sink)
        defer { ParolaLog.uninstall() }

        let libraryURL = try makeLibraryURL()
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        try setPermissions(0o000, on: libraryURL)
        defer { try? setPermissions(0o700, on: libraryURL) }

        let store = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        #expect(await store.list().isEmpty)

        let record = try #require(
            await waitForRecord(sink, .library, message: "library folder could not be listed")
        )
        #expect(record.level == .error)
        #expect(record.formattedLine.contains("/") == false)

        _ = await store.list()
        _ = await store.list()
        let listed = sink.records.filter { $0.message.rendered == "library folder could not be listed" }
        #expect(listed.count == 1, "logged once for the whole streak of failures")
    }

    @Test("bundles that cannot be read during a rebuild are counted once, not listed")
    func unreadableBundlesDuringRebuild() async throws {
        let sink = CapturingDiagnosticsSink()
        let libraryURL = try makeLibraryURL()
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let seed = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
        let broken = try await seed.add(transcript: makeTranscript("first"), audioSource: audio)
        _ = try await seed.add(transcript: makeTranscript("second"), audioSource: audio)
        await seed.flush()
        try Data("not json".utf8).write(to: broken.bundleURL.appendingPathComponent("transcript.json"))
        try FileManager.default.removeItem(at: libraryURL.appendingPathComponent(".search-index", isDirectory: true))

        await ParolaLog.withSink(sink) {
            let store = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
            _ = await store.search("second")
        }

        let matching = sink.records.filter {
            $0.category == .libraryIndex && $0.message.rendered == "bundles indexed on their title and notes alone"
        }
        let record = try #require(matching.first)
        #expect(record.level == .notice)
        #expect(record.fields[.count]?.text == "1")
        #expect(matching.count == 1)
        #expect(record.formattedLine.contains(broken.id) == false)
    }

    @Test("a transcript write that leaves disk ahead of memory is logged with its error kind")
    func transcriptWriteFailure() async throws {
        try await withSink { sink in
            let libraryURL = try makeLibraryURL()
            defer { try? FileManager.default.removeItem(at: libraryURL) }
            let store = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
            let audio = try makeAudio()
            defer { try? FileManager.default.removeItem(at: audio) }
            let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)
            try setPermissions(0o500, on: entry.bundleURL)
            defer { try? setPermissions(0o700, on: entry.bundleURL) }

            do {
                try await store.updateTranscript(self.makeTranscript("edited"), for: entry.id)
                Issue.record("expected a throw but none occurred")
            } catch {
            }

            let found = records(sink, .library, message: "transcript write left disk ahead of memory")
            #expect(found.count == 1)
            let record = try #require(found.first)
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains(entry.id) == false)
        }
    }

    @Test("a failed recache says the caches were dropped")
    func recacheFailure() async throws {
        try await withSink { sink in
            let libraryURL = try makeLibraryURL()
            defer { try? FileManager.default.removeItem(at: libraryURL) }
            let store = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
            let audio = try makeAudio()
            defer { try? FileManager.default.removeItem(at: audio) }
            let entry = try await store.add(transcript: makeTranscript(), audioSource: audio)
            let manifestURL = entry.bundleURL.appendingPathComponent("manifest.json")
            var manifest = try #require(
                JSONSerialization.jsonObject(with: try Data(contentsOf: manifestURL)) as? [String: Any]
            )
            manifest["version"] = 99
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

            do {
                try await store.setPinned(true, for: entry.id)
                Issue.record("expected a throw but none occurred")
            } catch {
            }

            let record = try #require(
                records(sink, .library, message: "entry recache failed, caches dropped").first
            )
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
        }
    }

    @Test("adopting a bundle that cannot be copied logs the rollback")
    func adoptRollback() async throws {
        try await withSink { sink in
            let sourceURL = try makeLibraryURL()
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            let source = LibraryStore(libraryURL: sourceURL, extraIndexer: nil)
            let audio = try makeAudio()
            defer { try? FileManager.default.removeItem(at: audio) }
            let entry = try await source.add(transcript: makeTranscript(), audioSource: audio)

            let libraryURL = try makeLibraryURL()
            defer { try? FileManager.default.removeItem(at: libraryURL) }
            let store = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
            try setPermissions(0o500, on: libraryURL)
            defer { try? setPermissions(0o700, on: libraryURL) }

            do {
                _ = try await store.adopt(parolaBundle: entry.bundleURL)
                Issue.record("expected a throw but none occurred")
            } catch {
            }

            let record = try #require(
                records(sink, .library, message: "adopting a bundle failed and was rolled back").first
            )
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains("parola") == false)
        }
    }

    @Test("a purge that cannot delete reports one count and the first error")
    func purgeFailures() async throws {
        try await withSink { sink in
            let libraryURL = try makeLibraryURL()
            defer { try? FileManager.default.removeItem(at: libraryURL) }
            let audio = try makeAudio()
            defer { try? FileManager.default.removeItem(at: audio) }
            let store = LibraryStore(libraryURL: libraryURL, extraIndexer: nil)
            let first = try await store.add(transcript: makeTranscript("one"), audioSource: audio)
            let second = try await store.add(transcript: makeTranscript("two"), audioSource: audio)
            try await store.delete(first.id)
            try await store.delete(second.id)
            try setPermissions(0o500, on: libraryURL)
            defer { try? setPermissions(0o700, on: libraryURL) }

            let result = await store.purgeDeletedOlderThan(
                days: 0, now: Date().addingTimeInterval(3600)
            )

            #expect(result.failed == 2)
            #expect(result.purgedIDs.isEmpty)
            let found = records(sink, .library, message: "deleted entries could not be purged")
            #expect(found.count == 1)
            let record = try #require(found.first)
            #expect(record.level == .error)
            #expect(record.fields[.count]?.text == "2")
            #expect(record.fields[.error] != nil)
        }
    }

    @Test("a snapshot write failure is logged once per run of failures")
    func snapshotWriteFailure() async throws {
        try await withSink { sink in
            let libraryURL = try makeLibraryURL()
            defer { try? FileManager.default.removeItem(at: libraryURL) }
            let indexDirectory = libraryURL.appendingPathComponent("snapshot-store", isDirectory: true)
            let attempts = OSAllocatedUnfairLock(initialState: 0)
            let index = LibrarySearchIndex(
                indexDirectory: indexDirectory,
                saveDebounce: .seconds(60),
                clock: ContinuousClock(),
                writeSnapshotData: { data, target in
                    let attempt = attempts.withLock { count -> Int in
                        count += 1
                        return count
                    }
                    guard attempt > 2 else { throw CocoaError(.fileWriteNoPermission) }
                    try data.write(to: target, options: .atomic)
                }
            )

            await index.index(id: "e1", title: "One", text: "sprint planning", createdAt: Date())
            await index.flush()
            await index.index(id: "e2", title: "Two", text: "retro feedback", createdAt: Date())
            await index.flush()

            let message = "search index snapshot write failed"
            let found = records(sink, .libraryIndex, message: message)
            #expect(found.count == 1)
            let record = try #require(found.first)
            #expect(record.level == .error)
            #expect(record.fields[.error]?.text == "NSCocoaErrorDomain.513")
            #expect(record.fields[.count]?.text == "1")
            #expect(record.formattedLine.contains("snapshot-store") == false)

            await index.index(id: "e3", title: "Three", text: "alpha review", createdAt: Date())
            await index.flush()
            #expect(records(sink, .libraryIndex, message: message).count == 1)
        }
    }

    @Test("a snapshot from an older version says it was discarded")
    func staleSnapshotDiscarded() async throws {
        try await withSink { sink in
            let libraryURL = try makeLibraryURL()
            defer { try? FileManager.default.removeItem(at: libraryURL) }
            let indexDirectory = libraryURL.appendingPathComponent("snapshot-store", isDirectory: true)
            try Data(#"{"version":1,"entries":[]}"#.utf8).write(to: indexDirectory.appendingPathExtension("json"))
            let index = LibrarySearchIndex(indexDirectory: indexDirectory)

            #expect(await index.needsRebuild(matching: [:]))

            let record = try #require(
                records(sink, .libraryIndex, message: "search index snapshot discarded, rebuilding").first
            )
            #expect(record.level == .notice)
            #expect(record.formattedLine.contains("snapshot-store") == false)
        }
    }
}
