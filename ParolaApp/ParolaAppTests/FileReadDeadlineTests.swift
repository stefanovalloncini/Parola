import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("File read deadline", .serialized)
    struct FileReadDeadlineTests {

        private func makeModel(fileReadDeadline: Duration = FileReadDeadline.header) -> AppModel {
            let bootstrap = AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("file-read-deadline"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: ContinuousClock(),
                fileReadDeadline: fileReadDeadline
            )
            return AppModel(bootstrap: bootstrap)
        }

        private func waitUntil(timeoutMs: Int = 15_000, _ condition: @MainActor () -> Bool) async -> Bool {
            var elapsed = 0
            while elapsed < timeoutMs {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(15))
                elapsed += 15
            }
            return condition()
        }

        /// A FIFO with no writer parks `open()` the way a TCC-denied folder or a stalled share does.
        @Test("a file that never opens ends the run instead of preparing forever")
        func wedgedOpenFailsTheRun() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.clear()
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("parola-app-fileread-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let wedged = dir.appendingPathComponent("wedged.m4a")
                #expect(mkfifo(wedged.path, 0o644) == 0, "could not create the FIFO the test needs")
                defer {
                    let writer = open(wedged.path, O_WRONLY | O_NONBLOCK)
                    if writer >= 0 { close(writer) }
                    try? FileManager.default.removeItem(at: dir)
                }

                await MockTranscriberRegistry.shared.install(
                    engineID: nil,
                    response: MockTranscriberResponse(
                        segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never reached")]
                    )
                )

                let model = makeModel(fileReadDeadline: .milliseconds(200))
                model.transcribe(fileURL: wedged)

                let failed = await waitUntil(timeoutMs: 5_000) {
                    if case .failed = model.phase { return true }
                    return false
                }
                #expect(failed, "the run should stop waiting on a file that never opens")
                guard case .failed(let message) = model.phase else { return }
                #expect(message == "Parola couldn't read wedged.m4a in time.")
                #expect(model.failedFileURL == wedged)
            }
        }

        @Test("the failure names the file and says the read ran out of time")
        func timeoutMessageNamesTheFile() {
            let message = AppModel.transcriptionFailureMessage(
                for: ParolaError.fileReadTimedOut(name: "New Recording 129.m4a")
            )
            #expect(message == "Parola couldn't read New Recording 129.m4a in time.")
        }
    }
}
