import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Recovery and library-save logging", .serialized, .logFacade)
struct RecoveryLoggingTests {
    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        ParolaLog.install(sink)
        defer { ParolaLog.uninstall() }
        try await body(sink)
    }

    private func records(
        _ sink: CapturingDiagnosticsSink, _ category: LogCategory, message: String
    ) -> [LogRecord] {
        sink.records.filter { $0.category == category && $0.message.rendered == message }
    }

    private func waitForRecord(
        _ sink: CapturingDiagnosticsSink, _ category: LogCategory, message: String
    ) async -> LogRecord? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let record = records(sink, category, message: message).first { return record }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return nil
    }

    private func makeModel(libraryURL: URL) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: UserDefaults(suiteName: "recovery-logging-\(UUID().uuidString)")!,
            libraryURL: libraryURL
        )
    }

    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")],
            language: "en",
            modelName: "stub"
        )
    }

    @Test("a transcript the library refuses is logged with its error kind, not its text")
    func librarySaveFailure() async throws {
        try await withSink { sink in
            let libraryURL = makeTempLibraryURL("recovery-logging-save")
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            let model = makeModel(libraryURL: libraryURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: libraryURL.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: libraryURL.path
                )
            }

            model.persistToLibrary(makeTranscript(), audioSource: nil, activate: false)

            let record = try #require(
                await waitForRecord(sink, .library, message: "transcript could not be saved to the library")
            )
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains("hi") == false)
            #expect(record.formattedLine.contains("/") == false)
        }
    }

    @Test("a checkpoint that cannot be encoded is logged instead of vanishing")
    func checkpointEncodeFailure() async throws {
        try await withSink { sink in
            let model = makeModel(libraryURL: makeTempLibraryURL("recovery-logging-encode"))
            _ = model.beginRecordingRecovery()
            // JSONEncoder refuses non-conforming floats, which is the only encode failure a
            // checkpoint can reach without a disk fault.
            model.liveSegments = [TranscriptSegment(id: 0, start: .infinity, end: 1, text: "hi")]
            model.writeRecordingCheckpoint()
            await model.pendingRecoveryWrite?.value

            let record = try #require(
                records(sink, .appRecovery, message: "recovery checkpoint could not be encoded").first
            )
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
        }
    }

    @Test("a checkpoint offered at launch names its kind and segment count")
    func checkpointOffered() async throws {
        try await withSink { sink in
            let libraryURL = makeTempLibraryURL("recovery-logging-offer")
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            let audio = libraryURL.appendingPathComponent("take.wav")
            try Data("RIFFfake".utf8).write(to: audio)
            let checkpoint = RecoveryCheckpoint(
                kind: .recording,
                startedAt: Date(),
                modelName: "stub",
                segments: [
                    TranscriptSegment(id: 0, start: 0, end: 1, text: "one"),
                    TranscriptSegment(id: 1, start: 1, end: 2, text: "two"),
                ],
                audioURL: audio
            )
            try JSONEncoder().encode(checkpoint)
                .write(to: libraryURL.appendingPathComponent("recovery.json"))
            let model = makeModel(libraryURL: libraryURL)

            model.loadPendingRecovery()

            #expect(model.pendingRecovery != nil)
            let record = try #require(
                records(sink, .appRecovery, message: "recovery checkpoint offered for recording").first
            )
            #expect(record.level == .notice)
            #expect(record.fields[.count]?.text == "2")
            #expect(record.formattedLine.contains("take.wav") == false)
        }
    }

    @Test("stale in-flight takes are reported as one count, never as file names")
    func staleTakesSwept() async throws {
        try await withSink { sink in
            let libraryURL = makeTempLibraryURL("recovery-logging-sweep")
            let model = makeModel(libraryURL: libraryURL)
            let inflight = model.inflightRecordingsURL
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let old = Date().addingTimeInterval(-72 * 3600)
            for name in ["take-one.wav", "take-two.wav"] {
                let url = inflight.appendingPathComponent(name)
                try Data("RIFFfake".utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }

            model.sweepInflightRecordings()

            let record = try #require(
                await waitForRecord(sink, .appRecovery, message: "stale in-flight takes deleted")
            )
            #expect(record.level == .notice)
            #expect(record.fields[.count]?.text == "2")
            #expect(record.formattedLine.contains("take-one") == false)
        }
    }
}
