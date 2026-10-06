import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Record over a run in flight", .serialized)
    struct RecordOverRunTests {

        @Test("Record during a file's run puts the file back in line, says so, and runs it after the take", .timeLimit(.minutes(1)))
        func fileRunWaitsForTheTake() async throws {
            let file = try makeTakeWAV("record-over-file")
            defer { try? FileManager.default.removeItem(at: file) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "the file's words")], partials: ["the file"], gate: gate)
                let model = makeRecordingModel("record-over-file")
                model.selectedModel = "openai_whisper-tiny"
                model.beginFileTranscription(fileURL: file, translateOverride: nil)
                await waitUntil { model.filePartialText == "the file" }

                try await startMeteredTake(model)

                #expect(model.deferredArrivals == [file])
                let message = model.exportNotice?.message
                #expect(message == "Stopped transcribing \(file.lastPathComponent). It starts again after the recording.")
                await gate.open()
                await model.discardTake()
                let ranAgain = await waitUntil(timeoutMs: 10_000) { await model.library.list().count == 1 }
                #expect(ranAgain)
            }
        }

        @Test("Record during a link's download puts the link back in line and says so", .timeLimit(.minutes(1)))
        func linkRunWaitsForTheTake() async throws {
            let audio = try makeTakeWAV("record-over-link")
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let model = makeRecordingModel("record-over-link")
                let fetchGate = FetchGate()
                model.linkFetcher = ScriptedLinkFetcher(fixture: audio, gate: fetchGate)
                let link = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
                model.transcribeYouTube(urlString: link)
                await waitUntil { model.transcribeTaskRunning }

                try await startMeteredTake(model)

                #expect(model.deferredLinks == [.transcribe(link)])
                let message = model.exportNotice?.message
                #expect(message == "Stopped transcribing \(link). It starts again after the recording.")
                model.deferredLinks = []
                await model.discardTake()
                await fetchGate.open()
            }
        }

        @Test("Record during a file's duplicate check puts the file back in line", .timeLimit(.minutes(1)))
        func duplicateCheckWaitsForTheTake() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parola-record-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let wedged = dir.appendingPathComponent("wedged.m4a")
            #expect(mkfifo(wedged.path, 0o644) == 0, "could not create the FIFO the test needs")
            defer {
                FIFOFixture.release(wedged)
                try? FileManager.default.removeItem(at: dir)
            }
            try await withMocksCleared(.transcriber) {
                let model = AppModel(bootstrap: AppBootstrap(
                    mode: .test, library: makeTempLibraryURL("record-over-check"), defaultsOverride: temporaryDefaults(),
                    sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock(), fileReadDeadline: .seconds(30)
                ))
                model.recordingCountInSeconds = 0
                model.freeDiskSpaceProvider = { 50_000_000_000 }
                model.transcribe(fileURL: wedged)
                #expect(model.transcribeTaskRunning)

                try await startMeteredTake(model)

                #expect(model.deferredArrivals == [wedged])
                model.deferredArrivals = []
                await model.discardTake()
            }
        }
    }
}
