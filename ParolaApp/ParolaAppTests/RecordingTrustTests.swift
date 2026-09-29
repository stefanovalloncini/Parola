import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private struct StubTake: LiveAudioSource {
    let url: URL
    func start() async throws {}
    func prepare() async throws -> URL { url }
    func cancel() async {}
}

private func makeTakeWAV(_ label: String) throws -> URL {
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
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-trust-\(label)-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Recording trust", .serialized)
    struct RecordingTrustTests {

        private func makeModel() -> AppModel {
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("recording-trust"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: ContinuousClock()
            ))
            model.recordingCountInSeconds = 0
            model.freeDiskSpaceProvider = { 50_000_000_000 }
            model.cardMetadataOperation = { _ in nil }
            return model
        }

        private func entries(_ model: AppModel, count: Int) async -> [LibraryEntry] {
            var listed: [LibraryEntry] = []
            await waitUntil { listed = await model.library.list(); return listed.count >= count }
            return listed
        }

        /// A take's transcription held by the gate, so the test acts while it is running.
        private func transcribingTake(_ model: AppModel, wav: URL) async {
            model.liveSource = StubTake(url: wav)
            model.phase = .recording(source: .microphone)
            model.stopRecordingAndTranscribe()
            await waitUntil { model.phase == .transcribing(file: wav) }
        }

        // MARK: - Stopping a take's transcription

        @Test("stopping a take's transcription saves the take and reports nothing")
        func stopTranscribingKeepsTheTake() async throws {
            let wav = try makeTakeWAV("stop")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never landed")],
                    gate: MockTranscriberGate()
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)
                let take = try #require(model.recordedTake)
                #expect(take.file == wav)
                #expect(take.title.hasPrefix("Recording "), "the pane names the take, not its file")

                model.stopTranscribingTake()
                #expect(model.phase == .idle)

                let saved = await entries(model, count: 1)
                #expect(saved.count == 1)
                #expect(saved.first?.title == take.title + " (not transcribed)")
                #expect(saved.first?.manifest.originalAudioName.isEmpty == false)
                await settle()
                #expect(model.phase == .idle, "a stop is not a failure")
                #expect(model.failedTakeAudioURL == wav, "Retry stays armed for the take")
            }
        }

        @Test("a cancel from anywhere else keeps the take too, with no error")
        func cancelCurrentWorkKeepsTheTake() async throws {
            let wav = try makeTakeWAV("cancel")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never landed")],
                    gate: MockTranscriberGate()
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)

                model.cancelCurrentWork()

                let saved = await entries(model, count: 1)
                #expect(saved.first?.title.hasSuffix("(not transcribed)") == true)
                await settle()
                #expect(model.phase == .idle)
            }
        }

        @Test("a cancellation never reaches the screen as its type name")
        func cancellationReadsPlainly() {
            let message = AppModel.transcriptionFailureMessage(for: CancellationError())
            #expect(!message.contains("CancellationError"))
            #expect(message == "Transcription stopped.")
        }

        // MARK: - Titles

        @Test("a finished take is named by its title, then by its entry, never by its working file")
        func finishedTakeNeverShowsItsFileName() async throws {
            let wav = try makeTakeWAV("title")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "a titled take")]
                ))
                let model = makeModel()
                model.liveSource = StubTake(url: wav)
                model.phase = .recording(source: .microphone)
                model.stopRecordingAndTranscribe()

                await waitUntil { model.phase == .ready }
                let title = try #require(model.recordedTake?.title)
                #expect(!title.contains("parola-trust"))

                await waitUntil { model.sourceFileURL != wav && model.selectedEntryID != nil }
                let entry = try #require(model.selectedEntryID.flatMap { model.libraryEntry(id: $0) })
                #expect(model.recordedTakeTitle(playing: model.sourceFileURL) == nil, "playback moved into the entry")
                #expect(AppModel.transcriptDisplayTitle(
                    sourceFileURL: model.sourceFileURL, entry: entry, showsAITitle: model.showAITitles, fallback: "Untitled"
                ) == title)
            }
        }
    }
}
