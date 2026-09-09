import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Subtitle import")
struct SubtitleImportTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
    }

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("subtitle-import"))
    }

    private static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeSrt(named name: String, in dir: URL) throws -> URL {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        Hello world.

        2
        00:00:02,500 --> 00:00:04,000
        Second line.
        """
        let url = dir.appendingPathComponent("\(name).srt")
        try Data(srt.utf8).write(to: url)
        return url
    }

    private static func writeVtt(named name: String, in dir: URL) throws -> URL {
        let vtt = """
        WEBVTT

        00:00.000 --> 00:02.000
        Ciao mondo.
        """
        let url = dir.appendingPathComponent("\(name).vtt")
        try Data(vtt.utf8).write(to: url)
        return url
    }

    private static func waitForEntries(in model: AppModel, timeout: TimeInterval = 3) async -> [LibraryEntry] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let entries = await model.library.list()
            if !entries.isEmpty { return entries }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await model.library.list()
    }

    @Test("an .srt file imports as a transcript and persists titled from its filename")
    func srtImportsAndPersists() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        let url = try Self.writeSrt(named: "meeting-notes", in: scratch)

        model.importSubtitle(fileURL: url)

        #expect(model.phase == .ready)
        #expect(model.transcript?.modelName == "imported-srt")
        #expect(model.transcript?.segments.count == 2)
        let entries = await Self.waitForEntries(in: model)
        #expect(entries.count == 1)
        #expect(entries.first?.title == "meeting-notes")
    }

    @Test("a .vtt file imports with the imported-vtt model name")
    func vttImportsWithModelName() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        let url = try Self.writeVtt(named: "talk", in: scratch)

        model.importSubtitle(fileURL: url)

        #expect(model.phase == .ready)
        #expect(model.transcript?.modelName == "imported-vtt")
        #expect(model.transcript?.segments.first?.text == "Ciao mondo.")
    }

    @Test("a file with no readable cues fails with a plain message")
    func malformedSubtitleFails() throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        let url = scratch.appendingPathComponent("garbage.srt")
        try Data("this is not a subtitle file".utf8).write(to: url)

        model.importSubtitle(fileURL: url)

        guard case .failed = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(model.transcript == nil)
    }

    @Test("a missing file fails instead of installing an empty transcript")
    func missingFileFails() {
        let model = makeModel()

        model.importSubtitle(fileURL: URL(fileURLWithPath: "/tmp/SubtitleImportTests/nope-\(UUID()).srt"))

        guard case .failed = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
    }

    @Test("transcribe(fileURL:) routes subtitle files to the importer")
    func transcribeRoutesSubtitles() throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        let url = try Self.writeSrt(named: "routed", in: scratch)

        model.transcribe(fileURL: url)

        #expect(model.phase == .ready)
        #expect(model.transcript?.modelName == "imported-srt")
    }

    @Test("subtitle arrivals during recording defer instead of stomping capture")
    func recordingDefersSubtitleImport() throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        model.phase = .recording(source: .microphone)
        let url = try Self.writeSrt(named: "deferred", in: scratch)

        model.importSubtitle(fileURL: url)

        #expect(model.deferredArrivals == [url])
        #expect(model.phase == .recording(source: .microphone))
        #expect(model.transcript == nil)
    }

    @Test("subtitle arrivals during a subtitle burn defer instead of stomping the export")
    func exportingDefersSubtitleImport() throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        model.phase = .exporting(progress: 0.5)
        let url = try Self.writeSrt(named: "deferred-export", in: scratch)

        model.importSubtitle(fileURL: url)

        #expect(model.deferredArrivals == [url])
        #expect(model.phase == .exporting(progress: 0.5))
        #expect(model.transcript == nil)
    }

    @Test("subtitle arrivals during a running batch defer instead of joining the queue")
    func runningBatchDefersSubtitleImport() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/a.wav")])
        await model.handleBatchEvent(.started(jobID: model.batchJobs[0].id))
        let url = try Self.writeSrt(named: "late", in: scratch)

        model.transcribe(fileURL: url)

        #expect(model.deferredArrivals == [url])
        #expect(!model.batchJobs.contains { $0.url == url })
    }

    @Test("deferred subtitles drain into the importer, not the batch")
    func drainRoutesSubtitlesToImport() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        model.phase = .recording(source: .microphone)
        let srt = try Self.writeSrt(named: "drained", in: scratch)
        let audio = URL(fileURLWithPath: "/tmp/audio.wav")
        model.transcribe(fileURL: srt)
        model.transcribe(fileURL: audio)
        #expect(model.deferredArrivals == [srt, audio])

        let final = Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "t")], language: "en", modelName: "m")
        await model.handleStreamingEvent(.finished(final))

        #expect(model.deferredArrivals.isEmpty)
        #expect(model.batchJobs.contains { $0.url == audio })
        #expect(!model.batchJobs.contains { $0.url == srt })
        #expect(model.transcript?.modelName == "imported-srt")
    }

    @Test("handleIncomingFiles splits subtitles from media")
    func handleIncomingFilesPartitions() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        let srt = try Self.writeSrt(named: "mixed", in: scratch)
        let wav1 = URL(fileURLWithPath: "/tmp/one.wav")
        let wav2 = URL(fileURLWithPath: "/tmp/two.wav")

        model.handleIncomingFiles([srt, wav1, wav2])
        await model.awaitBatchImport()

        #expect(model.transcript?.modelName == "imported-srt")
        #expect(model.batchJobs.map(\.url) == [wav1, wav2])
        #expect(model.deferredArrivals.isEmpty)
    }
}
