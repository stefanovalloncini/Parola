import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Error card retry", .serialized)
    struct ErrorRetryTests {

        private func makeModel() -> AppModel {
            let bootstrap = AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("error-retry"),
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
                .appendingPathComponent("parola-error-retry-\(UUID().uuidString).wav")
            try data.write(to: url)
            return url
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

        @Test("a failed file names the file and retries it with the current settings")
        func retryRunsTheSameFileAgain() async throws {
            await MockTranscriberRegistry.shared.clear()
            let wav = try makeWAV()
            defer {
                try? FileManager.default.removeItem(at: wav)
                Task { await MockTranscriberRegistry.shared.clear() }
            }

            await MockTranscriberRegistry.shared.install(
                engineID: nil,
                response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "the model could not read the audio")
                )
            )

            let model = makeModel()
            model.transcribe(fileURL: wav)
            let failed = await waitUntil {
                if case .failed = model.phase { return true }
                return false
            }
            #expect(failed)
            #expect(model.failedFileURL == wav)
            #expect(model.failedSourceName == wav.lastPathComponent)
            #expect(model.canRetryFailedTranscription)

            await MockTranscriberRegistry.shared.install(
                engineID: nil,
                response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the second run's words")]
                )
            )
            // The session holds the transcriber it already built, mock included.
            await model.session.unloadModel()
            model.retryFailedTranscription()
            let recovered = await waitUntil {
                model.phase == .ready && model.transcript?.text.contains("second run") == true
            }
            #expect(recovered)
            #expect(model.failedFileURL == nil)
            #expect(!model.canRetryFailedTranscription)
        }

        @Test("a translate-on retry keeps translate on, even if the toggle is off")
        func retryKeepsTheTranslateOverride() async throws {
            await MockTranscriberRegistry.shared.clear()
            let wav = try makeWAV()
            defer {
                try? FileManager.default.removeItem(at: wav)
                Task { await MockTranscriberRegistry.shared.clear() }
            }

            await MockTranscriberRegistry.shared.install(
                engineID: nil,
                response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom")
                )
            )

            let model = makeModel()
            model.translate = false
            model.transcribe(fileURL: wav, translateOverride: true)
            let failed = await waitUntil {
                if case .failed = model.phase { return true }
                return false
            }
            #expect(failed)
            #expect(model.failedTranslateOverride == true)

            model.retryFailedTranscription()
            let failedAgain = await waitUntil {
                if case .failed = model.phase { return true }
                return false
            }
            #expect(failedAgain)
            #expect(model.failedTranslateOverride == true, "Retry must not fall back to the current translate toggle")
        }

        @Test("opening an entry forgets the file the last failure named")
        func openingAnEntryForgetsTheFailedFile() async throws {
            await MockTranscriberRegistry.shared.clear()
            let wav = try makeWAV()
            defer {
                try? FileManager.default.removeItem(at: wav)
                Task { await MockTranscriberRegistry.shared.clear() }
            }

            await MockTranscriberRegistry.shared.install(
                engineID: nil,
                response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom")
                )
            )

            let model = makeModel()
            model.transcribe(fileURL: wav)
            let failed = await waitUntil {
                if case .failed = model.phase { return true }
                return false
            }
            #expect(failed)
            #expect(model.failedSourceName == wav.lastPathComponent)

            let seed = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
            let entry = try await seed.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "an older take")],
                    language: "en",
                    modelName: "stub"
                ),
                audioSource: nil,
                category: .transcription
            )
            model.loadEntry(entry.id)
            let opened = await waitUntil { model.selectedEntryID == entry.id }
            #expect(opened)
            #expect(model.failedFileURL == nil)
            #expect(model.failedSourceName == nil)
            #expect(!model.canRetryFailedTranscription)
        }

        @Test("a failure that isn't a transcription's keeps the generic card")
        func otherFailuresDoNotClaimAFile() async throws {
            await MockTranscriberRegistry.shared.clear()
            let wav = try makeWAV()
            defer {
                try? FileManager.default.removeItem(at: wav)
                Task { await MockTranscriberRegistry.shared.clear() }
            }

            await MockTranscriberRegistry.shared.install(
                engineID: nil,
                response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom")
                )
            )

            let model = makeModel()
            model.transcribe(fileURL: wav)
            let failed = await waitUntil {
                if case .failed = model.phase { return true }
                return false
            }
            #expect(failed)
            #expect(model.failureKind == .transcription)

            model.phase = .failed(message: "Save failed: the disk is full.")
            #expect(model.failureKind == .other)
            #expect(model.failedSourceName == nil)
            #expect(model.failedFileURL == nil)
            #expect(!model.canRetryFailedTranscription)
        }

        @Test("Retry runs the file itself while a batch is running")
        func retryDoesNotJoinTheBatch() async throws {
            await MockTranscriberRegistry.shared.clear()
            let wav = try makeWAV()
            defer {
                try? FileManager.default.removeItem(at: wav)
                Task { await MockTranscriberRegistry.shared.clear() }
            }

            await MockTranscriberRegistry.shared.install(
                engineID: nil,
                response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom")
                )
            )

            let model = makeModel()
            model.transcribe(fileURL: wav)
            let failed = await waitUntil {
                if case .failed = model.phase { return true }
                return false
            }
            #expect(failed)

            model.batchJobs = [BatchJob(url: URL(fileURLWithPath: "/tmp/batch-a.wav"), status: .transcribing)]
            #expect(model.batchIsRunning)

            await MockTranscriberRegistry.shared.install(
                engineID: nil,
                response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the second run's words")]
                )
            )
            // The session holds the transcriber it already built, mock included.
            await model.session.unloadModel()
            model.retryFailedTranscription()
            let recovered = await waitUntil {
                model.transcript?.text.contains("second run") == true
            }
            #expect(recovered, "Retry became a queue add instead of running the file")
            #expect(model.batchJobs.count == 1, "Retry must not append the file to the batch")
        }

        @Test("dismissing a failure forgets the file behind it")
        func dismissForgetsTheFailedFile() async throws {
            await MockTranscriberRegistry.shared.clear()
            let wav = try makeWAV()
            defer {
                try? FileManager.default.removeItem(at: wav)
                Task { await MockTranscriberRegistry.shared.clear() }
            }

            await MockTranscriberRegistry.shared.install(
                engineID: nil,
                response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom")
                )
            )

            let model = makeModel()
            model.transcribe(fileURL: wav)
            let failed = await waitUntil {
                if case .failed = model.phase { return true }
                return false
            }
            #expect(failed)

            model.dismissError()
            #expect(model.phase == .idle)
            #expect(model.failedFileURL == nil)
            #expect(model.failedSourceName == nil)
        }
    }
}
