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

/// Whether a quit asked, and the reply it handed back once the take was wound down.
@MainActor
private final class QuitReply {
    var value: Bool?
    var asked = false
}

private func makeTakeWAV(_ label: String, seconds: Double = 0.3) throws -> URL {
    let sampleRate = 16_000, channels = 1, bytesPerSample = 2
    let frames = Int(Double(sampleRate) * seconds)
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

        private func startStreamingTake(_ model: AppModel, gate: MockTranscriberGate? = nil, download: Double? = nil) async {
            MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                partials: ["hello"], downloadFractions: download.map { [$0] } ?? [], delayMs: 5_000, gate: gate
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

        @Test("a take stopped before transcribing keeps its checkpoint until its entry exists")
        func checkpointOutlivesTheSaveOnly() async throws {
            let wav = try makeTakeWAV("checkpoint", seconds: 3)
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never landed")],
                    gate: MockTranscriberGate()
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)
                await model.pendingRecoveryWrite?.value
                #expect(FileManager.default.fileExists(atPath: model.recoveryFileURL.path))

                model.stopTranscribingTake()

                var savedWithoutCheckpointFirst = false
                await waitUntil {
                    let checkpointGone = !FileManager.default.fileExists(atPath: model.recoveryFileURL.path)
                    let saved = await !model.library.list().isEmpty
                    if checkpointGone, !saved { savedWithoutCheckpointFirst = true }
                    return saved
                }
                #expect(!savedWithoutCheckpointFirst, "the checkpoint went before the take was in the library")
                await waitUntil { !FileManager.default.fileExists(atPath: model.recoveryFileURL.path) }
            }
        }

        @Test("a checkpoint a save still needs stays through cleanup, and goes when the save releases it")
        func heldCheckpointSurvivesCleanup() async throws {
            let model = makeModel()
            let generation = model.beginRecordingRecovery()
            model.liveRecordingAudioURL = URL(fileURLWithPath: "/tmp/parola-held-checkpoint.wav")
            model.writeRecordingCheckpoint()
            await model.pendingRecoveryWrite?.value
            model.recoveryHeldBySave.insert(generation)

            model.endActiveRecovery()
            #expect(FileManager.default.fileExists(atPath: model.recoveryFileURL.path))

            model.recoveryHeldBySave.remove(generation)
            model.endRecovery(generation)
            #expect(!FileManager.default.fileExists(atPath: model.recoveryFileURL.path))
        }

        // MARK: - A take's category and targets

        @Test("a take keeps the category and app targets it started with, whatever is asked for later")
        func takeKeepsItsCategoryAndTargets() async throws {
            let fixture = try makeTakeWAV("meeting")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.audioSource, .transcriber]) {
                await MockAudioSourceRegistry.shared.install(kind: .system, fixtureURL: fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "meeting words")]
                ))
                let model = makeModel()
                model.meetingCaptureAppOnly = true

                model.startMeetingRecording(appName: "Microsoft Teams")
                await waitUntil { model.liveSource != nil }
                let teams: Set<String> = ["com.microsoft.teams", "com.microsoft.teams2"]
                #expect(model.activeTake?.category == .meeting)
                #expect(model.activeTake?.captureTargets == teams)

                model.startMeetingRecording(appName: "Zoom")
                #expect(model.activeTake?.captureTargets == teams, "a refused request never reaches the running take")
                #expect(model.pendingRecordingCategory == .transcription)
                #expect(model.pendingCaptureBundleIDs == nil)

                model.stopRecordingAndTranscribe()
                let saved = try #require(await entries(model, count: 1).first)
                #expect(saved.category == .meeting)
                #expect(saved.title.hasPrefix("Meeting "))
            }
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
                #expect(!model.takeInProgress, "nothing captured yet, so quitting asks nothing")

                await gate.open()
                await waitUntil { model.recordingStartedAt != nil }
                #expect(model.takeArming == nil)
                #expect(model.takeInProgress)

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

        @Test("Cancel while a take arms goes home without a word, and Record works again at once", .timeLimit(.minutes(1)))
        func cancelWhileArmingIsQuiet() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                await startStreamingTake(model, gate: MockTranscriberGate(), download: 0.5)
                await waitUntil { model.takeArming != nil }

                model.cancelRecordingBeforeCapture()

                #expect(model.phase == .idle)
                #expect(!model.recordingActive, "a cancelled take doesn't hold the next one back")
                await settle()
                #expect(model.phase == .idle)
                #expect(model.takeArming == nil)
            }
        }

        @Test("events a finished take's session still sends never reach the take recording now", .timeLimit(.minutes(1)))
        func staleTakeEventsSpareTheNewTake() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                await startStreamingTake(model)
                await waitUntil { model.recordingStartedAt != nil }
                let startedAt = model.recordingStartedAt
                let ended = AppModel.TakeContext(id: -1, source: .microphone, category: .transcription, captureTargets: [])

                await model.handleStreamingEvent(.partial(text: "an older take"), take: ended)
                await model.handleStreamingEvent(.finished(Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "an older take")],
                    language: "en", modelName: "mock"
                )), take: ended)

                #expect(model.phase == .recording(source: .microphone))
                #expect(model.recordingStartedAt == startedAt)
                #expect(model.livePartialText != "an older take")
                #expect(model.takeInProgress)
                await settle()
                #expect(await model.library.list().isEmpty)
                model.cancelCurrentWork()
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

        // MARK: - Mac audio

        @Test("a system-audio take shows its meter and warns off the meter when it hears nothing")
        func systemAudioTakeIsNotBlind() async throws {
            let silent = try makeTakeWAV("mac-audio")
            defer { try? FileManager.default.removeItem(at: silent) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .system, fixtureURL: silent)
                let model = makeModel()
                model.silenceDetector = SilenceDetector(threshold: 0.5)
                model.startRecording(source: .systemAudio)
                await waitUntil { model.recordingLevelMeter != nil && model.recordingStartedAt != nil }
                #expect(AppModel.RecordSource.systemAudio.meterLabel == "Mac audio")

                // Two 750 ms ticks of the watch, and a slow host can stall the main actor for seconds.
                await waitUntil(timeoutMs: 15_000) { model.recordingIsSilent }

                model.cancelCurrentWork()
                #expect(!model.recordingIsSilent)
            }
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

        @Test("a take's title and its notes read in Italian")
        func takeTitlesReadInItalian() throws {
            let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
            let italian = try #require(Bundle(path: path))
            let endedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let stamp = AppFormat.dateAndTime(endedAt)

            let meeting = AppModel.liveRecordingTitle(category: .meeting, endedAt: endedAt, bundle: italian)
            #expect(meeting == "Riunione \(stamp)")
            #expect(AppModel.takeTitle(meeting, suffix: .notTranscribed, bundle: italian) == "Riunione \(stamp) (non trascritta)")
            #expect(AppModel.recoveredRecordingTitle(startedAt: endedAt, bundle: italian) == "Registrazione \(stamp) (recuperata)")
        }

        // MARK: - Quitting during a take

        @Test("quitting with no take in progress goes at once and asks nothing")
        func quitWithoutATakeAsksNothing() {
            let model = makeModel()
            let quit = QuitReply()
            let reply = AppDelegate.terminateReply(for: model, ask: { quit.asked = true; return .keepRecording }) { _ in }
            #expect(reply == .terminateNow)
            #expect(!quit.asked)
            #expect(AppDelegate.terminateReply(for: nil, ask: { .discard }) { _ in } == .terminateNow)
        }

        private func capturingTake(_ fixture: URL) async -> AppModel {
            await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
            let model = makeModel()
            model.useStreaming = false
            model.startRecording(source: .microphone)
            await waitUntil { model.takeInProgress }
            return model
        }

        @Test("Keep Recording cancels the quit and leaves the take running")
        func keepRecordingCancelsTheQuit() async throws {
            let fixture = try makeTakeWAV("keep")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                let model = await capturingTake(fixture)
                let quit = QuitReply()
                let reply = AppDelegate.terminateReply(for: model, ask: { .keepRecording }) { quit.value = $0 }
                #expect(reply == .terminateCancel)
                await settle()
                #expect(quit.value == nil)
                #expect(model.takeInProgress)
                model.cancelCurrentWork()
            }
        }

        @Test("Stop and Save puts the take in the library, then lets the app quit")
        func stopAndSaveKeepsTheTake() async throws {
            let fixture = try makeTakeWAV("save")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                let model = await capturingTake(fixture)
                let quit = QuitReply()
                let reply = AppDelegate.terminateReply(for: model, ask: { .stopAndSave }) { quit.value = $0 }
                #expect(reply == .terminateLater)

                await waitUntil { quit.value != nil }
                #expect(quit.value == true)
                let listed = await model.library.list()
                #expect(listed.count == 1, "the take is saved before the app is told it may quit")
                #expect(listed.first?.title.hasSuffix("(not transcribed)") == true)
                #expect(listed.first?.manifest.originalAudioName.isEmpty == false)
                #expect(!model.takeInProgress)
            }
        }

        @Test("Discard drops the take, then lets the app quit")
        func discardDropsTheTake() async throws {
            let fixture = try makeTakeWAV("discard")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                let model = await capturingTake(fixture)
                let quit = QuitReply()
                let reply = AppDelegate.terminateReply(for: model, ask: { .discard }) { quit.value = $0 }
                #expect(reply == .terminateLater)

                await waitUntil { quit.value != nil }
                #expect(quit.value == true)
                #expect(!model.takeInProgress)
                #expect(model.phase == .idle)
                await settle()
                #expect(await model.library.list().isEmpty)
            }
        }

        // MARK: - Legibility

        @Test("white on the Stop fill clears 4.5:1 in both appearances")
        func stopFillIsLegible() {
            let fill = DS.Color.recordingFillTheme.appearanceVariants
            let white = RGBA(1, 1, 1)
            #expect(white.contrast(against: fill.light) >= RGBA.textContrastMinimum)
            #expect(white.contrast(against: fill.dark) >= RGBA.textContrastMinimum)
        }

        @Test("warning banners set near-black text on solid amber, at 7:1 or more")
        func warningBannerIsLegible() {
            let amber = ThemePalette.sharedNeutrals.warning.appearanceVariants
            let ink = DS.Color.warningBannerInkRGBA
            #expect(ink.contrast(against: amber.light) >= 7)
            #expect(ink.contrast(against: amber.dark) >= 7)
        }
    }
}
