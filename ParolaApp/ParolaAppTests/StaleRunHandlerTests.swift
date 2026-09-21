import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Handlers from an abandoned run", .serialized)
    struct StaleRunHandlerTests {

        private func makeModel() -> AppModel {
            let bootstrap = AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("stale-run"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: ContinuousClock()
            )
            return AppModel(bootstrap: bootstrap)
        }

        private func makeWAV() throws -> URL {
            let sampleRate = 16_000, channels = 1, bytesPerSample = 2
            let frames = Int(Double(sampleRate) * 0.3)
            let dataBytes = frames * channels * bytesPerSample
            var data = Data()
            func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
            func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
            ascii("fmt "); le32(16); le16(1); le16(UInt16(channels))
            le32(UInt32(sampleRate)); le32(UInt32(sampleRate * channels * bytesPerSample))
            le16(UInt16(channels * bytesPerSample)); le16(UInt16(bytesPerSample * 8))
            ascii("data"); le32(UInt32(dataBytes))
            data.append(Data(count: dataBytes))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-stale-run-\(UUID().uuidString).wav")
            try data.write(to: url)
            return url
        }

        private func waitUntil(timeoutMs: Int = 10_000, _ condition: @MainActor () -> Bool) async -> Bool {
            var elapsed = 0
            while elapsed < timeoutMs {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(15))
                elapsed += 15
            }
            return condition()
        }

        /// The engine of an abandoned run can keep emitting; the pane belongs to whoever holds the
        /// current generation.
        @Test("a zombie run's partials, progress and stage never reach the pane")
        func staleHandlersAreDropped() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.clear()
                let wav = try makeWAV()
                defer { try? FileManager.default.removeItem(at: wav) }
                await MockTranscriberRegistry.shared.install(
                    engineID: nil,
                    response: MockTranscriberResponse(
                        segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the run's own words")]
                    )
                )

                let model = makeModel()
                let zombieToken = model.fileRunGeneration
                let zombiePartial = model.makeFilePartialHandler(runToken: zombieToken)
                let zombieProgress = model.makeFileProgressHandler(runToken: zombieToken)
                let zombieStage = model.makeFileStageHandler(fileURL: wav, runToken: zombieToken)

                model.transcribe(fileURL: wav)
                let finished = await waitUntil { model.phase == .ready }
                #expect(finished)
                #expect(model.fileRunGeneration != zombieToken)

                model.mediaDurationSeconds = 100
                model.filePartialText = "the live run's text"
                zombiePartial("zombie text")
                zombieProgress(50)
                zombieStage(.transcribing)
                try await Task.sleep(for: .milliseconds(200))

                #expect(model.filePartialText == "the live run's text")
                #expect(model.fileTranscribeFraction == nil)
                #expect(model.fileTranscribeStage == nil)
                #expect(model.phase == .ready)
            }
        }

        @Test("the live run's handlers still write")
        func liveHandlersStillWrite() async throws {
            let model = makeModel()
            let token = model.fileRunGeneration
            model.mediaDurationSeconds = 100
            model.makeFilePartialHandler(runToken: token)("live text")
            model.makeFileProgressHandler(runToken: token)(50)

            let landed = await waitUntil {
                model.filePartialText == "live text" && model.fileTranscribeFraction == 0.5
            }
            #expect(landed)
        }
    }
}
