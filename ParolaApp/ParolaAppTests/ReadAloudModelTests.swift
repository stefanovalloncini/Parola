import Foundation
import ParolaCore
import ParolaDictation
import ParolaSpeech
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Read Aloud entry points")
struct ReadAloudModelTests {
    private func makeModel(defaults: UserDefaults? = nil) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults ?? temporaryDefaults(), libraryURL: makeTempLibraryURL("read-aloud"))
    }

    private func transcript(
        language: String = "en",
        summary: Summary? = nil,
        translation: TranscriptTranslation? = nil,
        segments: Int = 4
    ) -> Transcript {
        var transcript = Transcript(
            segments: (0..<segments).map { index in
                TranscriptSegment(id: index, start: Double(index), end: Double(index) + 1, text: "Segment number \(index) says something.")
            },
            language: language,
            modelName: "stub"
        )
        transcript.summary = summary
        transcript.translation = translation
        return transcript
    }

    private func load(_ model: AppModel, _ transcript: Transcript) {
        model.transcript = transcript
        model.phase = .ready
    }

    @Test("a model made without bootstrap reads in silence: offline output and the recording Now Playing")
    func silentFromSkipBootstrap() async {
        let model = makeModel()
        load(model, transcript())

        let refusal = await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        #expect(refusal == nil)
        #expect(model.readAloud.mockVoice != nil)
        #expect(model.readAloud.nowPlayingPublisher is RecordingNowPlaying)
        #expect(model.readAloud.outputSink is PumpedOfflineSink)
        await model.stopReading()
    }

    @Test("the entry points read, pause, resume, skip and stop through the controller")
    func entryPoints() async {
        let model = makeModel()
        load(model, transcript())

        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }
        #expect(model.readAloud.item?.unitCount == 4)
        #expect(model.readAloud.item?.language == "en")

        await model.pauseReading()
        #expect(model.readAloud.state == .paused(.user))
        #expect(await model.resumeReading() == nil)
        #expect(model.readAloud.state == .reading)

        await model.skipReading(by: 1)
        await waitUntil { model.readAloud.item?.unitIndex == 1 }

        await model.stopReading()
        #expect(model.readAloud.state == .idle)
    }

    @Test("a segment to start from skips the ones before it")
    func readFromSegment() async {
        let model = makeModel()
        load(model, transcript())

        await model.readAloud(ReadAloudRequest(kind: .transcript, fromSegment: 2))
        await waitUntil { model.readAloud.state == .reading }

        #expect(model.readAloud.item?.unitCount == 2)
        #expect(model.readAloud.readingAnchors.map(\.anchor) == [.segment(2)])
        await model.stopReading()
    }

    @Test("an Italian transcript reads in Italian, and its translation in the target language")
    func languages() async {
        let model = makeModel()
        let translation = TranscriptTranslation(
            targetLanguage: "fr", segments: [0: "Bonjour.", 1: "Salut."], createdAt: Date(), provider: "mock"
        )
        load(model, transcript(language: "it", translation: translation))

        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }
        #expect(model.readAloud.item?.language == "it")

        await model.readAloud(ReadAloudRequest(kind: .translation))
        await waitUntil { model.readAloud.item?.language == "fr" && model.readAloud.state == .reading }
        #expect(model.readAloud.item?.source == .translation(language: "fr"))
        #expect(model.readAloud.item?.unitCount == 2)
        await model.stopReading()
    }

    @Test("the summary reads with its own source, and a transcript without one has nothing to read")
    func summarySource() async {
        let model = makeModel()
        load(model, transcript())
        #expect(await model.readAloud(ReadAloudRequest(kind: .summary)) == .nothingToRead)
        #expect(await model.readAloud(ReadAloudRequest(kind: .translation)) == .nothingToRead)

        load(model, transcript(summary: Summary(text: "The team agreed on the plan.", actionItems: ["Send the notes"])))
        #expect(await model.readAloud(ReadAloudRequest(kind: .summary)) == nil)
        await waitUntil { model.readAloud.state == .reading }
        #expect(model.readAloud.item?.source == .summary)
        #expect(model.readAloud.item?.unitCount == 2)
        await model.stopReading()
    }

    @Test("with no transcript or an unknown entry the request is refused")
    func refusals() async {
        let model = makeModel()
        #expect(await model.readAloud(ReadAloudRequest(kind: .transcript)) == .noTranscript)
        #expect(await model.readAloud(ReadAloudRequest(kind: .transcript, entryID: "missing")) == .unknownEntry)
    }

    @Test("a language with no voice ends in noVoice without playing")
    func noVoiceLanguage() async {
        let model = makeModel()
        load(model, transcript(language: "fa"))

        await model.readAloud(ReadAloudRequest(kind: .transcript))

        #expect(model.readAloud.state == .noVoice("fa"))
    }

    @Test("a long transcript builds its script off the main actor and still reads")
    func longTranscript() async {
        let model = makeModel()
        load(model, transcript(segments: TranscriptDerive.synchronousCap + 20))

        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        #expect(model.readAloud.item?.unitCount == TranscriptDerive.synchronousCap + 20)
        await model.stopReading()
    }

    @Test("a mock take pauses the reading, refuses Read and Resume with the reason, and allows both once it ends")
    func takeBlocks() async {
        let model = makeModel()
        load(model, transcript())
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        model.installTestTake(source: .microphone, liveSource: StubSource())
        await waitUntil { model.readAloud.state == .paused(.take) }

        #expect(model.readingBlockedReason == .take)
        #expect(await model.readAloud(ReadAloudRequest(kind: .transcript)) == .blocked(.take))
        #expect(await model.resumeReading() == .blocked(.take))

        model.endTestTake()
        #expect(model.readingBlockedReason == nil)
        #expect(model.readAloud.state == .paused(.take))
        #expect(await model.resumeReading() == nil)
        #expect(model.readAloud.state == .reading)
        await model.stopReading()
    }

    @Test("dictation that is not idle blocks reading; a failed one does not")
    func dictationBlocks() async {
        let model = makeModel()
        load(model, transcript())
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        model.dictationState = .listening
        await waitUntil { model.readAloud.state == .paused(.dictation) }
        #expect(await model.readAloud(ReadAloudRequest(kind: .transcript)) == .blocked(.dictation))

        model.dictationState = .failed("x")
        #expect(model.readingBlockedReason == nil)
        await model.stopReading()
    }

    @Test("a refused startRecording leaves a playing reading playing")
    func refusedTakeLeavesReading() async {
        let model = makeModel()
        load(model, transcript())
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        model.quitPending = true
        model.startRecording(source: .microphone)
        await settle()

        #expect(model.readAloud.state == .reading)
        await model.stopReading()
    }

    @Test("starting a take pauses the reading before the take does anything else")
    func startRecordingYields() async {
        let model = makeModel()
        load(model, transcript())
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }
        model.recordingCountInSeconds = 0
        model.freeDiskSpaceProvider = { 50_000_000_000 }
        model.useStreaming = false

        model.startRecording(source: .microphone)

        #expect(model.readAloud.state == .paused(.take))
        await model.discardTake()
        await model.stopReading()
    }

    @Test("dictation starting listens only after the reading has paused")
    func dictationHook() async {
        let model = makeModel()
        model.dictationController.recorderFactory = { _ in StubRecorder() }
        model.dictationEnabled = true
        model.startDictation()
        load(model, transcript())
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }

        model.dictationController.simulatePress()

        await waitUntil { model.readAloud.state == .paused(.dictation) }
        model.abortDictation()
        await model.stopReading()
    }

    @Test("the saved speed reaches the controller, survives a reload, and an unknown speed is ignored")
    func speedSetting() {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults: defaults)

        model.setReadingSpeed(1.5)
        #expect(model.readAloud.speed == 1.5)
        #expect(defaults.double(forKey: "readAloudRate") == 1.5)

        model.setReadingSpeed(3)
        #expect(model.readAloud.speed == 1.5)

        let reloaded = makeModel(defaults: defaults)
        #expect(reloaded.readAloudRate == 1.5)
        #expect(reloaded.readAloud.speed == 1.5)
    }

    @Test("the main player starting pauses the reading as media")
    func playerStartPausesReading() async {
        let model = makeModel()
        load(model, transcript())
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state == .reading }
        model.isPlaying = true
        await waitUntil { model.readAloud.state == .paused(.media) }
        await model.stopReading()
    }

    private struct StubSource: AudioSource {
        func prepare() async throws -> URL { URL(fileURLWithPath: "/tmp/stub-\(UUID()).wav") }
        func cancel() async {}
        func estimatedDuration() async -> Double? { nil }
    }
}

private struct StubRecorder: DictationRecorder {
    func start() async throws {}
    func stopAndTranscribe() async throws -> String { "" }
}
