import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// A capture the test drives: it comes up and hands back its file when let go, and meters only what the test records.
private actor StubCapture: LiveAudioSource {
    nonisolated let levelMeter = LevelMeter()
    private let file: URL
    private var holdsStart: Bool
    private var holdsPrepare: Bool
    private var held: CheckedContinuation<Void, Never>?

    init(file: URL, holdsStart: Bool = false, holdsPrepare: Bool = false) {
        self.file = file
        self.holdsStart = holdsStart
        self.holdsPrepare = holdsPrepare
    }

    func start() async throws {
        if holdsStart { await withCheckedContinuation { held = $0 } }
    }

    func prepare() async throws -> URL {
        if holdsPrepare { await withCheckedContinuation { held = $0 } }
        return file
    }

    func letGo() {
        holdsStart = false
        holdsPrepare = false
        held?.resume()
        held = nil
    }

    func cancel() async {}
}

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Recording session mirror", .serialized)
    struct RecordingSessionMirrorTests {
        private func makeModel() -> AppModel {
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .test, library: makeTempLibraryURL("session-mirror"), defaultsOverride: temporaryDefaults(),
                sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
            ))
            model.freeDiskSpaceProvider = { 50_000_000_000 }
            model.cardMetadataOperation = { _ in nil }
            return model
        }

        private func landedEntryID(_ model: AppModel) async -> LibraryEntry.ID? {
            var landed: LibraryEntry.ID?
            await waitUntil {
                if case .done(let id?) = model.recording?.state { landed = id }
                return landed != nil
            }
            return landed
        }

        private func startLiveTake(_ model: AppModel, _ response: MockTranscriberResponse) {
            MockStreamingTranscriberRegistry.shared.install(response)
            model.useStreaming = true
            model.selectedModel = "openai_whisper-tiny"
            model.startRecording(source: .microphone)
        }

        private func startStubTake(_ model: AppModel, _ capture: StubCapture, source: AppModel.RecordSource = .microphone) {
            model.useStreaming = false
            model.takeCaptureOverride = { _ in capture }
            model.startRecording(source: source)
        }

        private func seconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: .now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }

        @Test("a file take arms, then records from its first buffer, then finishes on Stop")
        func fileTakeStages() async throws {
            let fixture = try makeTakeWAV("mirror-stages")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.audioSource, .transcriber]) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(gate: MockTranscriberGate()))
                let model = makeModel()
                model.startRecording(source: .microphone)
                #expect(model.recording?.isArming == true)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                #expect(model.recordingStartedAt == model.recording?.startedAt)
                model.stopRecordingAndTranscribe()
                let stopped = model.recording.map { $0.state == .finishing || !$0.isRunning }
                #expect(stopped == true)

                model.cancelCurrentWork()
                await waitUntil { !model.hasPendingTakeWork }
            }
        }

        @Test("the take's levels fill at ten a second")
        func levelsFillAtTenASecond() async throws {
            let fixture = try makeTakeWAV("mirror-levels", seconds: 3)
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel()
                model.startRecording(source: .microphone)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)

                let before = model.takeLevels?.sampleCount ?? 0
                let from = ContinuousClock.now
                try await Task.sleep(for: .seconds(1))
                let after = model.takeLevels?.sampleCount ?? 0
                let rate = Double(after - before) / seconds(since: from)

                #expect(rate >= 7 && rate <= 13, "about ten levels a second, not \(rate)")
                model.cancelCurrentWork()
            }
        }

        @Test("a live take arms while its model loads, records from its first event, and lands on its entry")
        func liveTakeStages() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let gate = MockTranscriberGate()
                let model = makeModel()
                startLiveTake(model, MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "live words")],
                    partials: ["live"], downloadFractions: [0.42], delayMs: 200, gate: gate
                ))
                let preparing = await waitUntil {
                    model.recording?.state == .arming(.preparingModel(name: "openai_whisper-tiny", download: 0.42))
                }
                #expect(preparing)
                #expect(model.recording?.isStreaming == true)

                await gate.open()
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                model.stopRecordingAndTranscribe()
                #expect(model.recording?.state == .finishing)

                let entryID = try #require(await landedEntryID(model))
                let saved = await model.library.list().map(\.id)
                #expect(saved == [entryID])
            }
        }

        @Test("a live take stopped while its model loads ends its session with the reason")
        func liveTakeStoppedWhileLoading() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                startLiveTake(model, MockTranscriberResponse(
                    partials: ["never"], downloadFractions: [0.5], gate: MockTranscriberGate()
                ))
                let preparing = await waitUntil {
                    if case .arming(.preparingModel) = model.recording?.state { return true }
                    return false
                }
                #expect(preparing)

                model.stopRecordingAndTranscribe()

                let reason = AppModel.nothingRecordedMessage(for: .preparingModel(name: "openai_whisper-tiny", download: nil))
                #expect(model.recording?.state == .failed(message: reason))
                let settled = await waitUntil { !model.recordingActive }
                #expect(settled)
            }
        }

        @Test("a capture that comes up but never meters runs its watches at once and starts its clock from then after two seconds")
        func unheardCaptureFallsBack() async throws {
            let audio = try makeTakeWAV("mirror-unheard", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let model = makeModel()
            model.silenceRule = AppModel.SilenceRule(microphone: 60, macAudioBeforeSound: 0.5, macAudioAfterSound: 60)
            startStubTake(model, StubCapture(file: audio), source: .systemAudio)
            let up = await waitUntil { model.liveSource != nil }
            #expect(up)
            let cameUp = Date()
            #expect(model.recording?.isArming == true)
            #expect(model.takeInProgress, "a capture that is up holds audio a quit would lose")
            #expect(model.silenceWatchTask != nil)

            let warned = await waitUntil { model.recordingIsSilent }
            #expect(warned, "Mac audio that has heard nothing yet warns early")
            let started = await waitUntil { model.recording?.state == .recording }
            #expect(started)
            let startedAt = try #require(model.recording?.startedAt)
            #expect(abs(startedAt.timeIntervalSince(cameUp)) < 0.25)
            #expect(model.takeInProgress)
            model.cancelCurrentWork()
        }

        @Test("a capture that meters starts its clock at its first reading, not when it came up")
        func clockStartsAtTheFirstReading() async throws {
            let audio = try makeTakeWAV("mirror-heard", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let model = makeModel()
            let capture = StubCapture(file: audio)
            startStubTake(model, capture)
            let up = await waitUntil { model.liveSource != nil }
            #expect(up)
            try await Task.sleep(for: .milliseconds(300))

            let heardAt = Date()
            capture.levelMeter.record(0.4)

            let started = await waitUntil { model.recording?.state == .recording }
            #expect(started)
            let startedAt = try #require(model.recording?.startedAt)
            #expect(abs(startedAt.timeIntervalSince(heardAt)) < 0.05)
            model.cancelCurrentWork()
        }

        @Test("a buffer metered just before Stop counts: the take is kept and its clock starts at that reading")
        func stopRightAfterTheFirstReading() async throws {
            let audio = try makeTakeWAV("mirror-first-reading", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "just in time")]
                ))
                let model = makeModel()
                let capture = StubCapture(file: audio)
                startStubTake(model, capture)
                let up = await waitUntil { model.liveSource != nil }
                #expect(up)
                try await Task.sleep(for: .milliseconds(300))

                let heardAt = Date()
                capture.levelMeter.record(0.4)
                model.stopRecordingAndTranscribe()

                #expect(model.recording?.state == .finishing)
                let startedAt = try #require(model.recording?.startedAt)
                #expect(abs(startedAt.timeIntervalSince(heardAt)) < 0.05)
                let entryID = try #require(await landedEntryID(model))
                let saved = await model.library.list().map(\.id)
                #expect(saved == [entryID])
            }
        }

        @Test("a Stop after the capture came up but before it metered anything keeps a file that holds audio")
        func unheardTakeWithAudioIsKept() async throws {
            let audio = try makeTakeWAV("mirror-unheard-audio", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "kept anyway")]
                ))
                let model = makeModel()
                startStubTake(model, StubCapture(file: audio))
                let up = await waitUntil { model.liveSource != nil }
                #expect(up)
                let cameUp = Date()

                model.stopRecordingAndTranscribe()

                #expect(model.recording?.state == .finishing)
                let startedAt = try #require(model.recording?.startedAt)
                #expect(abs(startedAt.timeIntervalSince(cameUp)) < 0.25, "counted from when the capture came up")
                let entryID = try #require(await landedEntryID(model))
                let saved = await model.library.list().map(\.id)
                #expect(saved == [entryID])
            }
        }

        @Test("a Stop after the capture came up but before it metered anything records nothing when the file is empty, and deletes it")
        func unheardEmptyTakeIsDropped() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "an empty take is never transcribed")
                ))
                let model = makeModel()
                try FileManager.default.createDirectory(at: model.inflightRecordingsURL, withIntermediateDirectories: true)
                let empty = try makeTakeWAV("mirror-unheard-empty", seconds: 0, in: model.inflightRecordingsURL, prefix: "parola-mic")
                startStubTake(model, StubCapture(file: empty))
                let up = await waitUntil { model.liveSource != nil }
                #expect(up)

                model.stopRecordingAndTranscribe()

                let message = AppModel.nothingRecordedMessage()
                let ended = await waitUntil { model.recording?.state == .failed(message: message) }
                #expect(ended)
                #expect(model.phase == .idle, "the take's failure shows on its Stage, not in the phase")
                #expect(!FileManager.default.fileExists(atPath: empty.path), "an empty take's file goes")
                await settle()
                let saved = await model.library.list()
                #expect(saved.isEmpty)
            }
        }

        @Test("a Stop before the capture came up records nothing, and the capture that comes up later is dropped")
        func stopBeforeTheCaptureCameUp() async throws {
            let audio = try makeTakeWAV("mirror-not-up", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let model = makeModel()
            let capture = StubCapture(file: audio, holdsStart: true)
            startStubTake(model, capture)
            let starting = await waitUntil {
                model.takeArming == .startingCapture && model.activeTake?.captureRequested == true
            }
            #expect(starting)
            #expect(model.liveSource == nil)

            model.stopRecordingAndTranscribe()

            let message = AppModel.nothingRecordedMessage()
            #expect(model.recording?.state == .failed(message: message))
            #expect(model.phase == .idle)
            await capture.letGo()
            let settled = await waitUntil { !model.recordingActive }
            #expect(settled)
            #expect(model.liveSource == nil, "the late capture is dropped")
        }

        @Test("a take whose file comes back after the next take started leaves that take's levels running")
        func lateFileSparesTheNextTake() async throws {
            let firstFile = try makeTakeWAV("mirror-late-first", seconds: 1)
            let secondFile = try makeTakeWAV("mirror-late-second", seconds: 1)
            defer {
                try? FileManager.default.removeItem(at: firstFile)
                try? FileManager.default.removeItem(at: secondFile)
            }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "the first take is not the point")
                ))
                let model = makeModel()
                let first = StubCapture(file: firstFile, holdsPrepare: true)
                startStubTake(model, first)
                let firstUp = await waitUntil { model.liveSource != nil }
                #expect(firstUp)
                model.stopRecordingAndTranscribe()
                model.cancelCurrentWork()

                let second = StubCapture(file: secondFile)
                startStubTake(model, second)
                let secondUp = await waitUntil { model.liveSource != nil }
                #expect(secondUp)
                await first.letGo()
                let firstDone = await waitUntil { !model.hasPendingTakeWork }
                #expect(firstDone)

                #expect(model.recordingLevelMeter === second.levelMeter, "the first take's late clear left the second take's meter")
                second.levelMeter.record(0.4)
                let started = await waitUntil { model.recording?.state == .recording }
                #expect(started, "the second take's sampler still runs")
                model.cancelCurrentWork()
            }
        }

        @Test("Stop and Save on a quit keeps a capture that came up but metered nothing when its file holds audio")
        func quitKeepsAnUnheardTakeWithAudio() async throws {
            let audio = try makeTakeWAV("mirror-quit-unheard", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let model = makeModel()
            startStubTake(model, StubCapture(file: audio))
            let up = await waitUntil { model.liveSource != nil }
            #expect(up)
            #expect(model.takeInProgress, "the quit asks, since the capture is up")

            let quits = await model.resolveQuitDuringTake(.stopAndSave)

            #expect(quits)
            let saved = await model.library.list()
            #expect(saved.count == 1)
            #expect(saved.first?.title.hasSuffix("(not transcribed)") == true)
        }

        @Test("Stop and Save on a quit drops a capture that came up but metered nothing when its file is empty")
        func quitDropsAnUnheardEmptyTake() async throws {
            let model = makeModel()
            try FileManager.default.createDirectory(at: model.inflightRecordingsURL, withIntermediateDirectories: true)
            let empty = try makeTakeWAV("mirror-quit-empty", seconds: 0, in: model.inflightRecordingsURL, prefix: "parola-mic")
            startStubTake(model, StubCapture(file: empty))
            let up = await waitUntil { model.liveSource != nil }
            #expect(up)

            let quits = await model.resolveQuitDuringTake(.stopAndSave)

            #expect(quits)
            #expect(!FileManager.default.fileExists(atPath: empty.path))
            let saved = await model.library.list()
            #expect(saved.isEmpty)
            #expect(model.recording == nil)
        }

        @Test("a count-in is the take's first arming, and it hands the same take to the capture")
        func countInHandsOver() async throws {
            let fixture = try makeTakeWAV("mirror-count-in", seconds: 2)
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel()
                model.recordingCountInSeconds = 1
                model.startRecording(source: .microphone)
                #expect(model.recording?.state == .arming(.countIn(remaining: 1)))
                #expect(model.recordingCountdown == 1)
                let countIn = try #require(model.recording?.takeID)

                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                #expect(model.recording?.takeID == countIn)
                #expect(model.recordingCountdown == nil)
                model.cancelCurrentWork()
            }
        }

        @Test("cancelling a count-in leaves no take behind")
        func countInCancelled() {
            let model = makeModel()
            model.recordingCountInSeconds = 3
            model.startRecording(source: .microphone)
            #expect(model.recordingCountdown == 3)

            model.cancelRecordingCountdown()

            #expect(model.recording == nil)
            #expect(model.recordingCountdown == nil)
        }

        @Test("a take refused before it starts keeps the reason in its session")
        func refusedTakeFails() async {
            let model = makeModel()
            model.freeDiskSpaceProvider = { 100_000_000 }

            model.startRecording(source: .microphone)

            let refusal = AppModel.diskSpaceRefusalMessage()
            let refused = await waitUntil { model.recording?.state == .failed(message: refusal) }
            #expect(refused)
            #expect(model.phase == .idle)
            #expect(model.route == .recording, "the refusal shows on the take's Stage")
        }

        @Test("a take cancelled while it records leaves no session")
        func cancelledTakeLeavesNoSession() async throws {
            let fixture = try makeTakeWAV("mirror-cancel", seconds: 2)
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel()
                model.startRecording(source: .microphone)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)

                model.cancelCurrentWork()

                #expect(model.recording == nil)
                #expect(model.takeLevels == nil)
                #expect(model.recordingStartedAt == nil)
            }
        }

        @Test("a stopped take transcribes in its session, and its save lands it on the entry")
        func fileTakeLandsOnItsEntry() async throws {
            let fixture = try makeTakeWAV("mirror-lands")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.audioSource, .transcriber]) {
                let gate = MockTranscriberGate()
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "kept words")], gate: gate
                ))
                let model = makeModel()
                model.startRecording(source: .microphone)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                model.stopRecordingAndTranscribe()
                let transcribing = await waitUntil { model.recording?.state == .transcribing(progress: nil) }
                #expect(transcribing)
                #expect(model.recordingStartedAt == nil, "a take transcribing no longer counts as recording")

                await gate.open()

                let entryID = try #require(await landedEntryID(model))
                let saved = await model.library.list().map(\.id)
                #expect(saved == [entryID])
            }
        }

        @Test("an older take's late save never touches the take recording now")
        func olderTakeLeavesTheNewSessionAlone() async throws {
            let fixture = try makeTakeWAV("mirror-two-takes", seconds: 2)
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.audioSource, .transcriber]) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the first take")], gate: MockTranscriberGate()
                ))
                let model = makeModel()
                model.startRecording(source: .microphone)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                model.stopRecordingAndTranscribe()
                let transcribing = await waitUntil { model.recording?.state == .transcribing(progress: nil) }
                #expect(transcribing)
                let first = try #require(model.recording?.takeID)

                model.startRecording(source: .microphone)
                let second = try #require(model.recording?.takeID)
                #expect(second != first)
                let firstSaved = await waitUntil { await !model.library.list().isEmpty }
                #expect(firstSaved, "the first take is saved untranscribed")
                await settle()

                #expect(model.recording?.takeID == second)
                #expect(model.recording?.isRunning == true)
                model.cancelCurrentWork()
            }
        }
    }
}
