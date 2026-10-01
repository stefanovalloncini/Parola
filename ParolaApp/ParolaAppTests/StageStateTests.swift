import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// A capture whose file comes back only when the test lets it go, and then cut short.
private actor HeldCutShortCapture: LiveAudioSource {
    nonisolated let levelMeter = LevelMeter()
    private let file: URL
    private var released = false
    private var held: CheckedContinuation<Void, Never>?

    init(file: URL) { self.file = file }

    func start() async throws {}

    func prepare() async throws -> URL {
        if !released { await withCheckedContinuation { held = $0 } }
        throw CaptureInterrupted(url: file, reason: "the disk is full")
    }

    func letGo() {
        released = true
        held?.resume()
        held = nil
    }

    func cancel() async {}
}

@Suite("Stage states")
struct StageStateTests {
    @Test("each session state has one Stage look")
    func modes() {
        #expect(StageMode.for(.arming(.countIn(remaining: 2)), isStreaming: false) == .countIn(2))
        #expect(StageMode.for(.arming(.preparingModel(name: "Whisper Turbo", download: 0.42)), isStreaming: true)
            == .preparing("Whisper Turbo", 0.42))
        #expect(StageMode.for(.arming(.startingCapture), isStreaming: false) == .starting)
        #expect(StageMode.for(.recording, isStreaming: true) == .live)
        #expect(StageMode.for(.paused(since: Date()), isStreaming: false) == .paused)
        #expect(StageMode.for(.finishing, isStreaming: false) == .finishing)
        #expect(StageMode.for(.transcribing(progress: 0.5), isStreaming: false) == .transcribing(0.5))
        #expect(StageMode.for(.done(entryID: "E"), isStreaming: false) == .landing)
        #expect(StageMode.for(.failed(message: "The microphone stopped."), isStreaming: false)
            == .failed("The microphone stopped."))
    }

    @Test("a session reads its own mode")
    func sessionMode() {
        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .countIn(remaining: 3)
        )
        #expect(take.mode == .countIn(3))
        _ = take.markCapturing(at: Date())
        #expect(take.mode == .live)
    }

    @Test("a paused clock blinks at half a hertz: a second full, a second dimmed")
    func pausedBlink() {
        #expect(PausedBlink.opacity(at: 0) == 1)
        #expect(PausedBlink.opacity(at: 0.99) == 1)
        #expect(PausedBlink.opacity(at: 1) == PausedBlink.dimmed)
        #expect(PausedBlink.opacity(at: 1.99) == PausedBlink.dimmed)
        #expect(PausedBlink.opacity(at: 2) == 1)
        #expect(PausedBlink.opacity(at: 3.5) == PausedBlink.dimmed)
        #expect(PausedBlink.dimmed > 0, "the time stays readable through the dim half")
    }

    @Test("the controls are the bar until Stop, one Finishing pill while the take winds down, and none once it is over")
    func controlsLayout() {
        #expect(StageControls.layout(for: .countIn(3)) == .bar)
        #expect(StageControls.layout(for: .live) == .bar)
        #expect(StageControls.layout(for: .paused) == .bar)
        #expect(StageControls.layout(for: .finishing) == .finishing)
        #expect(StageControls.layout(for: .transcribing(0.5)) == .stopTranscribing)
        #expect(StageControls.layout(for: .landing) == .none)
        #expect(StageControls.layout(for: .failed("x")) == .none)
    }

    @Test("the facts line counts the run's progress, and says so while the engine prepares the audio")
    func transcribingLine() {
        #expect(StageFacts.transcribingLine(stage: .preparingAudio, progress: nil) == "Preparing audio…")
        #expect(StageFacts.transcribingLine(stage: nil, progress: nil) == "Transcribing…")
        #expect(StageFacts.transcribingLine(stage: .transcribing, progress: 0.42) == "Transcribing… · 42%")
        #expect(StageFacts.transcribingLine(stage: .preparingAudio, progress: 0.1) == "Transcribing… · 10%")
    }

    @MainActor
    @Test("the overview squeezes the whole take into the width and sweeps as far as the run has read")
    func overviewLayout() {
        let minute = TakeLevelHistory()
        for _ in 0..<600 { minute.append(0.5) }
        let squeezed = TakeOverviewLayout(levels: minute, width: 300, progress: 0.5)
        #expect(squeezed.bars.count == 100)
        #expect(squeezed.step == 3)
        #expect(abs(squeezed.secondsPerBar - 0.6) < 0.0001)
        #expect(abs(squeezed.elapsed - 60) < 0.0001)
        #expect(squeezed.sweptBars == 50)
        #expect(abs(squeezed.x(at: 30) - 150) < 0.0001)
        #expect(squeezed.tickInterval == 10)

        let short = TakeLevelHistory()
        for _ in 0..<100 { short.append(0.5) }
        let loose = TakeOverviewLayout(levels: short, width: 300, progress: nil)
        #expect(loose.bars.count == 100, "ten seconds fill a third of the width, one bar per sample")
        #expect(abs(loose.secondsPerBar - 0.1) < 0.0001)
        #expect(abs(loose.elapsed - 10) < 0.0001)
        #expect(loose.sweptBars == 0)
        #expect(loose.tickInterval == 2)

        let empty = TakeOverviewLayout(levels: nil, width: 300, progress: 0.5)
        #expect(empty.bars.isEmpty)
        #expect(empty.elapsed == 0)
    }

    @Test("a stopped take's words show from their newest end, never the whole run's text")
    func takeTextTail() {
        #expect(StageTakeText.shown("a few words") == "a few words")
        let hour = String(repeating: "word ", count: 20_000) + "last"
        let shown = StageTakeText.shown(hour)
        #expect(shown.count <= StageTakeText.recentCharacters)
        #expect(shown.hasSuffix("word last"))
        #expect(shown.hasPrefix("word "), "the cut never starts mid-word")
    }

    @MainActor
    @Test("a failed take offers Show in Finder once its failure saved the audio, and its band greys")
    func failedTakeLook() {
        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture
        )
        #expect(!StageBand.greys(take.state))
        take.fail("Nothing was recorded.")
        #expect(StageBand.greys(take.state))
        #expect(!ErrorBanner.showsTakeInFinder(take), "nothing was recorded, so there is nothing to show")
        take.failure = RecordingSession.Failure(
            audioURL: URL(fileURLWithPath: "/tmp/parola-stage-failed.wav"),
            save: Task<LibraryEntry, any Error> { throw CancellationError() },
            recovery: nil, title: "R", category: .transcription, source: .microphone, annotations: AppModel.TakeAnnotations()
        )
        #expect(ErrorBanner.showsTakeInFinder(take))
    }

    @MainActor
    @Test("the saved toast names the place the take went, and goes after three seconds")
    func toast() {
        #expect(TakeSavedToast.message(category: .meeting) == "Saved to Meetings")
        #expect(TakeSavedToast.message(category: .transcription) == "Saved to Transcriptions")
        #expect(TakeSavedToast.dismissAfter == .seconds(3))
    }

    @Test("the time slot names the model a live take waits on, with its download")
    func preparingLine() {
        #expect(StageTimeSlot.preparingText(name: "openai_whisper-large-v3_turbo", download: 0.42) == "Preparing Whisper Turbo · 42%")
        #expect(StageTimeSlot.preparingText(name: "openai_whisper-large-v3_turbo", download: nil) == "Preparing Whisper Turbo…")
    }
}

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Stage state flows", .serialized)
    struct StageStateFlowTests {
        private static let pinnedModel = "openai_whisper-tiny"

        private func makeModel(_ label: String) -> AppModel {
            let model = makeRecordingModel(label)
            model.useStreaming = false
            model.selectedModel = Self.pinnedModel
            return model
        }

        /// A live take held while its model "loads", so it stays arming until the gate opens.
        private func startPreparingTake(_ model: AppModel, gate: MockTranscriberGate) async {
            MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                partials: ["hello"], downloadFractions: [0.5], delayMs: 5_000, gate: gate
            ))
            model.useStreaming = true
            model.startRecording(source: .microphone)
            await waitUntil { model.activeTake?.captureRequested == true }
        }

        @Test("a stopped take transcribes on its Stage, over the whole take, until Stop Transcribing keeps the audio")
        func transcribesOnTheStage() async throws {
            let audio = try makeTakeWAV("stage-transcribing", seconds: 2)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "words")], partials: ["some", "some words"], gate: gate)
                let model = makeModel("stage-transcribing")

                recordAndStop(model, audio: audio, seconds: 2)

                let streamed = await waitUntil { model.takePartialText == "some words" }
                #expect(streamed)
                let take = try #require(model.recording)
                #expect(take.isTranscribing)
                #expect(model.route == .recording)
                #expect(ContentRoutes.stageShows(take, model: model), "the Stage keeps the take while its run reports to it")

                model.stopTranscribingTake()

                let letGo = try #require(model.recording)
                #expect(!ContentRoutes.stageShows(letGo, model: model), "the Stage hands over once the run lets go")
                let saved = try #require(await landedEntry(model))
                #expect(saved.title.hasSuffix("(not transcribed)"))
                await gate.open()
            }
        }

        @Test("a take cut short after Stop and Cancel still says so, while Record works again at once")
        func cutShortAfterCancelReports() async throws {
            let audio = try makeTakeWAV("stage-cut-after-cancel", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let model = makeModel("stage-cut-after-cancel")
            let capture = HeldCutShortCapture(file: audio)
            model.takeCaptureOverride = { _ in capture }
            model.startRecording(source: .microphone)
            let up = await waitUntil { model.liveSource != nil }
            #expect(up)
            model.stopRecordingAndTranscribe()
            #expect(model.recording?.state == .finishing)

            model.cancelCurrentWork()

            #expect(!model.recordingActive, "the stopped take no longer holds up the next one")
            #expect(model.route != .recording, "Cancel leaves the Stage")
            #expect(model.recording?.isOver == false, "the take lands only once its save does")
            await capture.letGo()
            let message = "Parola couldn't keep writing the recording to disk. The recording up to this point was saved to your library."
            let reported = await waitUntil { model.recording?.state == .failed(message: message) }
            #expect(reported)
            let notice = await waitForNotice(model)
            #expect(notice?.message == message)
            #expect(notice?.actions.map(\.title) == ["Retry", "Show"])
            let saved = await landedEntry(model)
            #expect(saved?.title.hasSuffix("(interrupted)") == true)
        }

        @Test("a take whose transcription fails keeps its Stage, with Retry and Show in Finder on the audio it saved")
        func failedTakeKeepsItsStage() async throws {
            let audio = try makeTakeWAV("stage-failed", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "the engine gave up")
                ))
                let model = makeModel("stage-failed")

                recordAndStop(model, audio: audio, seconds: 1)

                var message: String?
                let failed = await waitUntil {
                    if case .failed(let text) = model.recording?.state { message = text }
                    return message != nil
                }
                #expect(failed)
                let take = try #require(model.recording)
                #expect(model.route == .recording)
                #expect(ContentRoutes.stageShows(take, model: model), "the Stage stays with the failed take")
                #expect(message?.hasSuffix("The audio was saved to your library.") == true)
                #expect(take.failure != nil, "Retry has what it needs")
                #expect(ErrorBanner.showsTakeInFinder(take))
                let failure = try #require(take.failure)
                let shown = await model.savedAudio(of: failure)
                let landed = await landedEntry(model)
                let entry = try #require(landed)
                #expect(entry.title.hasSuffix("(transcription failed)"))
                let inLibrary = shown?.path.hasPrefix(model.library.libraryURL.path) ?? false
                let exists = shown.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                #expect(inLibrary, "Finder shows the entry's copy, not the working file")
                #expect(exists)

                model.dismissTakeFailure()
                #expect(model.recording == nil)
                #expect(model.route != .recording)
            }
        }

        @Test("a take that lands on its Stage says where it went, and Copy puts its words on the pasteboard")
        func landingSaysWhereItWent() async throws {
            let audio = try makeTakeWAV("stage-saved", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "the words of the take")])
                let model = makeModel("stage-saved")
                model.pendingRecordingCategory = .meeting

                recordAndStop(model, audio: audio, seconds: 1)

                let toasted = await waitUntil { model.takeSavedNotice != nil }
                #expect(toasted)
                let landed = await landedEntry(model)
                let entry = try #require(landed)
                let notice = try #require(model.takeSavedNotice)
                #expect(notice.entryID == entry.id)
                #expect(notice.category == .meeting)
                #expect(model.recording?.state == .done(entryID: entry.id))
                #expect(model.route == .transcript, "the take landed on its transcript")

                let pasteboard = NSPasteboard(name: NSPasteboard.Name("stage-saved-\(UUID())"))
                await model.copySavedTake(entry.id, to: pasteboard)
                #expect(pasteboard.string(forType: .string) == "the words of the take")
                #expect(model.takeSavedNotice == nil, "Copy takes the toast down")
            }
        }

        @Test("the saved toast offers Summarize only while a summary can be written, and Summarize shows one")
        func savedTakeSummarize() async throws {
            let model = makeModel("stage-saved-summary")
            model.aiUnavailableReason = "Apple Intelligence is turned off."
            #expect(!TakeSavedToast.offersSummary(model))
            model.aiUnavailableReason = nil
            #expect(TakeSavedToast.offersSummary(model))

            let words = Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "a take worth a summary")], language: "en", modelName: "stub"
            )
            let entry = try await model.library.add(transcript: words, audioSource: nil, category: .meeting)
            model.selectedEntryID = entry.id
            model.transcript = words
            model.summariseOperation = { _, _ in Summary(text: "the gist") }
            model.takeSavedNotice = TakeSavedNotice(entryID: entry.id, category: .meeting)

            model.summarizeSavedTake(entry.id)

            let summarized = await waitUntil { model.transcript?.summary?.text == "the gist" }
            #expect(summarized)
            #expect(model.transcriptPaneMode == .summary)
            #expect(model.takeSavedNotice == nil)
        }

        @Test("the Stage's Cancel ends a count-in with no word")
        func cancelDuringCountIn() {
            let model = makeModel("stage-cancel-count-in")
            model.recordingCountInSeconds = 60
            model.startRecording(source: .microphone)
            #expect(model.recordingCountdown == 60)
            #expect(model.route == .recording)

            model.cancelArmingTake()

            #expect(model.recording == nil)
            #expect(model.recordingCountdown == nil)
            #expect(model.exportNotice == nil)
            #expect(model.phase == .idle)
        }

        @Test("the Stage's Cancel ends a take still loading its model with no word")
        func cancelWhilePreparing() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel("stage-cancel-preparing")
                let gate = MockTranscriberGate()
                await startPreparingTake(model, gate: gate)
                let preparing = await waitUntil { model.recording?.mode == .preparing(Self.pinnedModel, 0.5) }
                #expect(preparing)

                model.cancelArmingTake()

                #expect(model.recording == nil)
                #expect(model.exportNotice == nil)
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
                await gate.open()
                await settle()
                #expect(model.recording == nil)
                #expect(model.phase == .idle)
                let saved = await model.library.list()
                #expect(saved.isEmpty)
            }
        }
    }
}
