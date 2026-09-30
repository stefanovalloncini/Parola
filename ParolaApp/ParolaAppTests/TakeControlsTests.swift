import Foundation
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// A capture the test drives: it comes up at once, meters only what the test records, and keeps every pause it is told.
private actor ScriptedCapture: LiveAudioSource {
    nonisolated let levelMeter = LevelMeter()
    private let file: URL
    private(set) var pauseCalls: [Bool] = []

    init(file: URL) {
        self.file = file
    }

    func start() async throws {}
    func prepare() async throws -> URL { file }
    func cancel() async {}
    func setPaused(_ paused: Bool) async { pauseCalls.append(paused) }
    func inFlightURL() async -> URL? { file }
}

private struct SleepRequest {
    let at: ContinuousClock.Instant
    let length: Duration
}

/// Every sleep asked of the clock, when it was asked and for how long.
private final class SleepLog: Sendable {
    private let requests = OSAllocatedUnfairLock<[SleepRequest]>(initialState: [])

    func note(_ length: Duration) {
        requests.withLock { $0.append(SleepRequest(at: .now, length: length)) }
    }

    func longerThan(_ floor: Duration) -> [SleepRequest] {
        requests.withLock { $0 }.filter { $0.length > floor }
    }
}

/// The continuous clock, with a note of every sleep asked of it.
private struct SleepLogClock: Clock {
    typealias Instant = ContinuousClock.Instant
    let log: SleepLog

    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { ContinuousClock().minimumResolution }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        log.note(ContinuousClock.now.duration(to: deadline))
        try await ContinuousClock().sleep(until: deadline, tolerance: tolerance)
    }
}

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Take controls", .serialized)
    struct TakeControlsTests {
        private func startScriptedTake(_ model: AppModel, _ capture: ScriptedCapture) async throws {
            model.useStreaming = false
            model.takeCaptureOverride = { _ in capture }
            model.startRecording(source: .microphone)
            let up = await waitUntil { model.liveSource != nil }
            guard up else { throw FixtureTakeDidNotStart() }
            capture.levelMeter.record(0.4)
            let recording = await waitUntil { model.recording?.state == .recording }
            guard recording else { throw FixtureTakeDidNotStart() }
        }

        private func startLiveTake(_ model: AppModel, _ response: MockTranscriberResponse) {
            MockStreamingTranscriberRegistry.shared.install(response)
            model.useStreaming = true
            model.selectedModel = "openai_whisper-tiny"
            model.startRecording(source: .microphone)
        }

        // MARK: - Pause

        @Test("pausing stops the file from growing and resuming picks up")
        func pauseResume() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("take-pause")
                try await startFixtureTake(model)
                #expect(model.pauseTake())
                #expect(model.recording?.isPaused == true)
                #expect(!model.pauseTake())
                #expect(model.resumeTake())
                #expect(model.recording?.state == .recording)
                model.cancelCurrentWork()
            }
        }

        @Test("the capture is told to pause and resume in the order asked, while the clock, the levels and the silence watch hold")
        func pauseReachesTheCapture() async throws {
            let audio = try makeTakeWAV("take-pause-capture", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let model = makeRecordingModel("take-pause-capture")
            let capture = ScriptedCapture(file: audio)
            try await startScriptedTake(model, capture)
            #expect(model.silenceWatchTask != nil)

            #expect(model.pauseTake())
            let heldAt = try #require(model.recording?.elapsed(at: Date()))
            let levelsAtPause = model.takeLevels?.sampleCount ?? 0
            #expect(model.silenceWatchTask == nil)
            #expect(!model.recordingIsSilent)
            try await Task.sleep(for: .milliseconds(400))
            let drift = (model.recording?.elapsed(at: Date()) ?? 0) - heldAt
            #expect(abs(drift) < 0.001, "a paused clock stands still")
            #expect(model.takeLevels?.sampleCount == levelsAtPause, "a pause adds nothing to the take's levels")

            #expect(model.resumeTake())
            #expect(model.pauseTake())
            #expect(model.resumeTake())
            #expect(model.silenceWatchTask != nil)
            let told = await waitUntil { await capture.pauseCalls.count == 4 }
            #expect(told)
            #expect(await capture.pauseCalls == [true, false, true, false])
            let levelsMove = await waitUntil { (model.takeLevels?.sampleCount ?? 0) > levelsAtPause }
            #expect(levelsMove)
            model.cancelCurrentWork()
        }

        @Test("Pause and markers wait while a take arms; once it records they work")
        func armingRefusesPause() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let gate = MockTranscriberGate()
                let model = makeRecordingModel("take-pause-arming")
                startLiveTake(model, MockTranscriberResponse(partials: ["live"], delayMs: 5_000, gate: gate))
                let preparing = await waitUntil {
                    if case .arming(.preparingModel) = model.recording?.state { return true }
                    return false
                }
                #expect(preparing)

                #expect(!model.pauseTake())
                #expect(model.addTakeMarker() == nil)
                #expect(model.recording?.isArming == true)

                await gate.open()
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                #expect(model.pauseTake())
                #expect(model.recording?.isPaused == true)
                model.cancelCurrentWork()
            }
        }

        @Test("a pause holds the auto-stop: resuming counts down what was left, not a new limit")
        func pauseHoldsTheAutoStop() async throws {
            let audio = try makeTakeWAV("take-auto-stop", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let log = SleepLog()
            let model = makeRecordingModel("take-auto-stop", clock: SleepLogClock(log: log))
            model.recordingMaxMinutes = 2
            try await startScriptedTake(model, ScriptedCapture(file: audio))
            let scheduled = await waitUntil { log.longerThan(.seconds(90)).count == 1 }
            #expect(scheduled)
            try await Task.sleep(for: .milliseconds(300))

            let pausedAt = ContinuousClock.now
            #expect(model.pauseTake())
            #expect(model.recordingAutoStopTask == nil)
            try await Task.sleep(for: .milliseconds(600))
            #expect(model.resumeTake())

            let rescheduled = await waitUntil { log.longerThan(.seconds(90)).count == 2 }
            #expect(rescheduled)
            let limits = log.longerThan(.seconds(90))
            let first = try #require(limits.first)
            let second = try #require(limits.last)
            let expected = first.length - first.at.duration(to: pausedAt)
            let off = second.length - expected
            #expect(off < .milliseconds(100) && off > .milliseconds(-100), "left \(second.length), expected about \(expected)")
            model.cancelCurrentWork()
        }

        // MARK: - Markers

        @Test("a marker becomes a favourite once the transcript lands")
        func markerBecomesFavourite() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeRecordingModel("take-marker")
                await installMockTranscriber(segments: [(0, 4, "Hello"), (4, 9, "The launch is on the 14th")])
                try await startFixtureTake(model)
                try await Task.sleep(for: .milliseconds(1200))
                #expect(model.addTakeMarker() != nil)
                model.stopRecordingAndTranscribe()
                let entry = try #require(await landedEntry(model))
                #expect(!entry.favoriteSegments.isEmpty)
                #expect(entry.favoriteSegments == [0])
                #expect(entry.manifest.takeMarkers?.count == 1)
            }
        }

        @Test("markers outlive a take saved untranscribed, and favourite their sentence once it is transcribed")
        func markersWaitForTheTranscript() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 0.2, "Hi"), (0.2, 9, "The launch is on the 14th")], gate: gate)
                let model = makeRecordingModel("take-marker-later")
                try await startFixtureTake(model)
                try await Task.sleep(for: .milliseconds(500))
                let mark = try #require(model.addTakeMarker())
                model.stopRecordingAndTranscribe()
                let transcribing = await waitUntil { model.recording?.state == .transcribing(progress: nil) }
                #expect(transcribing)

                model.stopTranscribingTake()
                let saved = try #require(await landedEntry(model))
                #expect(saved.manifest.takeMarkers == [mark])
                #expect(saved.favoriteSegments.isEmpty)

                model.loadEntry(saved.id)
                let opened = await waitUntil { model.selectedEntryID == saved.id && model.transcript != nil }
                #expect(opened)
                await gate.open()
                model.transcribeLoadedEntry()
                let favoured = await waitUntil { model.libraryEntry(id: saved.id)?.favoriteSegments == [1] }
                #expect(favoured)
            }
        }

        @Test("Retry after a failed transcription favourites the take's markers in the entry the failure saved")
        func retryKeepsMarkers() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "engine boom")
                ))
                let model = makeRecordingModel("take-marker-retry")
                try await startFixtureTake(model)
                try await Task.sleep(for: .milliseconds(500))
                #expect(model.addTakeMarker() != nil)
                model.stopRecordingAndTranscribe()
                let failed = await waitUntil { model.canRetryFailedTranscription && !model.hasPendingTakeWork }
                #expect(failed)
                let saved = try #require(await landedEntry(model))
                #expect(saved.favoriteSegments.isEmpty)

                await installMockTranscriber(segments: [(0, 0.2, "Hi"), (0.2, 9, "The launch is on the 14th")])
                await model.unloadTranscriptionSession()
                model.retryFailedTranscription()
                let favoured = await waitUntil { model.libraryEntry(id: saved.id)?.favoriteSegments == [1] }
                #expect(favoured)
                #expect(await model.library.list().count == 1, "Retry lands in the entry the failure saved")
            }
        }

        // MARK: - Discard

        @Test("Discard deletes the take's audio and adds nothing to the library")
        func discard() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("take-discard")
                try await startFixtureTake(model, copyingFixture: true)
                let audio = try #require(model.recording?.audioURL)
                await model.discardTake()
                #expect(model.recording == nil || model.recording?.isOver == true)
                #expect(!FileManager.default.fileExists(atPath: audio.path))
                #expect(model.libraryEntries.isEmpty)
            }
        }

        @Test("Discarding a paused take ends its checkpoint, saves nothing, and Record works again")
        func discardPausedTake() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("take-discard-paused")
                try await startFixtureTake(model, copyingFixture: true)
                await model.pendingRecoveryWrite?.value
                #expect(model.recoveryCheckpointFiles.count == 1)
                #expect(model.pauseTake())

                await model.discardTake()

                #expect(!model.recordingActive)
                #expect(model.recoveryCheckpointFiles.isEmpty)
                await settle()
                #expect(await model.library.list().isEmpty)
                try await startFixtureTake(model)
                #expect(model.recording?.state == .recording)
                model.cancelCurrentWork()
            }
        }

        @Test("Discard ends a live take with nothing saved")
        func discardLiveTake() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeRecordingModel("take-discard-live")
                startLiveTake(model, MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never kept")], partials: ["live"], delayMs: 300
                ))
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)

                await model.discardTake()

                #expect(model.recording == nil)
                #expect(!model.recordingActive)
                await settle()
                #expect(await model.library.list().isEmpty)
            }
        }

        @Test("Discard while a take arms ends it the way Cancel does: quietly, with nothing to delete")
        func discardWhileArming() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeRecordingModel("take-discard-arming")
                startLiveTake(model, MockTranscriberResponse(partials: ["never"], gate: MockTranscriberGate()))
                let preparing = await waitUntil {
                    if case .arming(.preparingModel) = model.recording?.state { return true }
                    return false
                }
                #expect(preparing)

                await model.discardTake()

                #expect(model.recording == nil)
                let settled = await waitUntil { !model.recordingActive }
                #expect(settled)
                #expect(model.phase == .idle)
            }
        }

        @Test("Discard during a count-in ends it before any take begins")
        func discardDuringCountIn() async {
            let model = makeRecordingModel("take-discard-count-in")
            model.recordingCountInSeconds = 60
            model.startRecording(source: .microphone)
            #expect(model.recordingCountdown == 60)

            await model.discardTake()

            #expect(model.recordingCountdown == nil)
            #expect(!model.takeIsRunning)
        }

        @Test("after Stop, Pause and Discard do nothing; the take finishes and lands")
        func controlsAfterStop() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeRecordingModel("take-after-stop")
                await installMockTranscriber(segments: [(0, 2, "Hi")])
                try await startFixtureTake(model)
                model.stopRecordingAndTranscribe()
                #expect(!model.pauseTake())
                await model.discardTake()
                #expect(try #require(await landedEntry(model)).title.isEmpty == false)
            }
        }

        // MARK: - Title and category

        @Test("a typed title and a switch to Meeting survive into the saved entry")
        func titleAndCategory() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeRecordingModel("take-title")
                await installMockTranscriber(segments: [(0, 2, "Hi")])
                try await startFixtureTake(model)
                model.renameTake("Design review")
                model.setTakeCategory(.meeting)
                model.stopRecordingAndTranscribe()
                let entry = try #require(await landedEntry(model))
                #expect(entry.title == "Design review")
                #expect(entry.category == .meeting)
                #expect(entry.manifest.titleSource == .user)
            }
        }

        @Test("an untyped title follows the category, and clearing a typed one brings the generated name back")
        func untypedTitleFollowsTheCategory() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeRecordingModel("take-untyped-title")
                await installMockTranscriber(segments: [(0, 2, "Hi")])
                try await startFixtureTake(model)
                model.setTakeCategory(.meeting)
                #expect(model.recording?.category == .meeting)
                #expect(model.recording?.title.hasPrefix("Meeting ") == true)

                model.renameTake("Design review")
                #expect(model.recording?.title == "Design review")
                model.renameTake("   ")
                #expect(model.recording?.titleSource == nil)
                #expect(model.recording?.title.hasPrefix("Meeting ") == true)

                model.stopRecordingAndTranscribe()
                let entry = try #require(await landedEntry(model))
                #expect(entry.title.hasPrefix("Meeting "))
                #expect(entry.manifest.titleSource == nil)
                #expect(entry.category == .meeting)
            }
        }

        @Test("a typed title is saved as typed when the take lands untranscribed, and stays once it is transcribed")
        func typedTitleCarriesNoNote() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 2, "Hi")], gate: gate)
                let model = makeRecordingModel("take-typed-untranscribed")
                try await startFixtureTake(model)
                model.renameTake("Design review")
                model.stopRecordingAndTranscribe()
                let transcribing = await waitUntil { model.recording?.state == .transcribing(progress: nil) }
                #expect(transcribing)
                #expect(model.recordedTake?.title == "Design review")

                model.stopTranscribingTake()
                let saved = try #require(await landedEntry(model))
                #expect(saved.title == "Design review")
                #expect(saved.manifest.titleSource == .user)

                model.loadEntry(saved.id)
                let opened = await waitUntil { model.selectedEntryID == saved.id && model.transcript != nil }
                #expect(opened)
                await gate.open()
                model.transcribeLoadedEntry()
                let transcribed = await waitUntil { model.transcript?.text == "Hi" }
                #expect(transcribed)
                await model.awaitLandingSteps()
                #expect(await model.library.list().first?.title == "Design review")
            }
        }

        @Test("once Stop is pressed, a name, a category or a marker no longer reaches the take")
        func lateChangesAreIgnored() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeRecordingModel("take-late-changes")
                await installMockTranscriber(segments: [(0, 2, "Hi")])
                try await startFixtureTake(model)
                model.stopRecordingAndTranscribe()

                model.renameTake("Too late")
                model.setTakeCategory(.meeting)
                #expect(model.addTakeMarker() == nil)
                #expect(!model.resumeTake())

                let entry = try #require(await landedEntry(model))
                #expect(entry.title != "Too late")
                #expect(entry.category == .transcription)
                #expect(entry.manifest.takeMarkers == nil)
            }
        }

        @Test("a live take that is finishing takes no more names, categories, markers, pauses or discards")
        func finishingLiveTakeIsSettled() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeRecordingModel("take-finishing-live")
                startLiveTake(model, MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 30, text: "live words")],
                    partials: ["one", "two", "three", "four"], delayMs: 2_000
                ))
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                model.stopRecordingAndTranscribe()
                #expect(model.recording?.state == .finishing)

                model.renameTake("Too late")
                model.setTakeCategory(.meeting)
                #expect(model.addTakeMarker() == nil)
                #expect(!model.pauseTake())
                await model.discardTake()

                let entry = try #require(await landedEntry(model))
                #expect(entry.title != "Too late")
                #expect(entry.category == .transcription)
                #expect(entry.manifest.takeMarkers == nil)
            }
        }

        @Test("a category chosen while a live take is still starting holds once it records")
        func categoryChosenWhileStarting() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeRecordingModel("take-category-starting")
                startLiveTake(model, MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "live words")], partials: ["live"], delayMs: 200
                ))
                model.setTakeCategory(.meeting)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                #expect(model.activeTake?.category == .meeting)

                model.stopRecordingAndTranscribe()

                let entry = try #require(await landedEntry(model))
                #expect(entry.category == .meeting)
            }
        }

        @Test("an untitled take is saved under the one name it showed, stamped when it began, through a category switch")
        func untitledTakeKeepsTheNameItShowed() async throws {
            let wav = try makeTakeWAV("take-shown-name")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 2, "Hi")])
                let model = makeRecordingModel("take-shown-name")
                let began = Date(timeIntervalSinceNow: -3_600)
                model.installTestTake(source: .microphone, liveSource: StubSource(url: wav), startedAt: began)
                #expect(model.recording?.title == AppModel.liveRecordingTitle(category: .transcription, endedAt: began))

                model.setTakeCategory(.meeting)
                model.renameTake("Design review")
                model.renameTake("")
                let shown = AppModel.liveRecordingTitle(category: .meeting, endedAt: began)
                #expect(model.recording?.title == shown)

                model.stopRecordingAndTranscribe()

                let entry = try #require(await landedEntry(model))
                #expect(entry.title == shown)
                #expect(entry.manifest.titleSource == nil)
            }
        }

        @Test("a live take keeps the title, category and markers it was given")
        func liveTakeKeepsWhatItWasGiven() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeRecordingModel("take-live-details")
                startLiveTake(model, MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 30, text: "live words")], partials: ["live"], delayMs: 200
                ))
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                model.renameTake("Standup")
                model.setTakeCategory(.meeting)
                #expect(model.addTakeMarker() != nil)

                model.stopRecordingAndTranscribe()

                let entry = try #require(await landedEntry(model))
                #expect(entry.title == "Standup")
                #expect(entry.manifest.titleSource == .user)
                #expect(entry.category == .meeting)
                #expect(entry.favoriteSegments == [0])
            }
        }
    }
}
