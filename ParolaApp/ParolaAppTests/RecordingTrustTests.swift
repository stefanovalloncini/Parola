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

        private func startStreamingTake(_ model: AppModel, gate: MockTranscriberGate, download: Double) async {
            MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                partials: ["hello"], downloadFractions: [download], delayMs: 5_000, gate: gate
            ))
            model.useStreaming = true
            model.selectedModel = "openai_whisper-tiny"
            model.startRecording(source: .microphone)
            await waitUntil { model.phase == .recording(source: .microphone) }
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

        // MARK: - Arming

        @Test("a live take arms until its first event, then starts its clock", .timeLimit(.minutes(1)))
        func armingThenRecording() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let gate = MockTranscriberGate()
                let model = makeModel()
                await startStreamingTake(model, gate: gate, download: 0.42)

                await waitUntil {
                    model.takeArming == .preparingModel(name: "openai_whisper-tiny", download: 0.42)
                }
                #expect(model.recordingStartedAt == nil)

                await gate.open()
                await waitUntil { model.recordingStartedAt != nil }
                #expect(model.takeArming == nil)

                model.cancelCurrentWork()
                await waitUntil { model.recordingLevelMeter == nil }
                #expect(model.recordingStartedAt == nil)
            }
        }

        @Test("finishing a take while its model loads ends it at once and says nothing was recorded", .timeLimit(.minutes(1)))
        func finishWhileArmingSaysSo() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                await startStreamingTake(model, gate: MockTranscriberGate(), download: 0.5)
                await waitUntil { model.takeArming != nil }

                model.stopRecordingAndTranscribe()

                let expected = AppModel.nothingRecordedMessage(for: .preparingModel(name: "openai_whisper-tiny", download: nil))
                #expect(expected == "Nothing was recorded — the model was still loading.")
                #expect(model.phase == .failed(message: expected))
                await waitUntil { !model.recordingActive }
                await settle()
                #expect(model.phase == .failed(message: expected), "the cancelled load must not replace the message")
                #expect(await model.library.list().isEmpty)
            }
        }

        @Test("Cancel while a take arms goes home without a word", .timeLimit(.minutes(1)))
        func cancelWhileArmingIsQuiet() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                await startStreamingTake(model, gate: MockTranscriberGate(), download: 0.5)
                await waitUntil { model.takeArming != nil }

                model.cancelRecordingBeforeCapture()

                #expect(model.phase == .idle)
                await waitUntil { !model.recordingActive }
                await settle()
                #expect(model.phase == .idle)
                #expect(model.takeArming == nil)
            }
        }

        // MARK: - The take's clock

        @Test("the take's clock and levels live on the model, so a page change keeps them")
        func clockSurvivesARouteChange() async throws {
            let fixture = try makeTakeWAV("clock")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel()
                model.useStreaming = false
                model.startRecording(source: .microphone)
                await waitUntil { model.recordingStartedAt != nil }
                let startedAt = try #require(model.recordingStartedAt)
                let trace = try #require(model.recordingLevelTrace)

                model.route = .statistics
                await settle(for: .milliseconds(50))
                model.route = .transcript

                #expect(model.recordingStartedAt == startedAt)
                #expect(model.recordingLevelTrace === trace)
                #expect(AppDelegate.recordingBadge(startedAt: startedAt, now: startedAt.addingTimeInterval(75)) == "1:15")

                model.cancelCurrentWork()
            }
        }

        @Test("the Dock badge waits while a take arms and turns over with the take's own seconds")
        func dockBadgeReadsTheTakeClock() {
            let start = Date(timeIntervalSinceReferenceDate: 1_000)
            #expect(AppDelegate.recordingBadge(startedAt: nil, now: start) == "…")
            #expect(AppDelegate.recordingBadge(startedAt: start, now: start.addingTimeInterval(3_725)) == "1:02:05")
            #expect(abs(AppDelegate.secondsToNextTick(startedAt: start, now: start.addingTimeInterval(2.3)) - 0.7) < 0.000_1)
            #expect(AppDelegate.secondsToNextTick(startedAt: nil, now: start) == 1)
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
