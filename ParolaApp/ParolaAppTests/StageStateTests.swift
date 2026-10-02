import AppKit
import Foundation
import os
import SwiftUI
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

/// A live session whose last check holds the landing until the test lets it go, so a Cancel can arrive mid-landing.
private actor HeldLandingSession: StreamingTranscriber {
    nonisolated let levelMeter = LevelMeter()
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
    func cancel() async {}
    func currentModel() async -> String? { nil }

    func audioWasCutShort() async -> Bool {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
        return false
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

/// Stands still: each sleep waits until the test opens its gate, and notes how long it asked for.
private struct HeldClock: Clock {
    typealias Instant = ContinuousClock.Instant
    let gate = FetchGate()
    let asked = OSAllocatedUnfairLock<[Duration]>(initialState: [])
    let now = ContinuousClock.now
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        asked.withLock { $0.append(now.duration(to: deadline)) }
        await gate.wait()
        try Task.checkCancellation()
    }
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

    @Test("whatever ends the take shares Stop's glass, so the bar folds into the Finishing pill and on into Stop Transcribing")
    func controlsMorphThroughStop() {
        let stop = StageControls.glassShape(.stop, reduceMotion: false)
        #expect(stop != nil)
        #expect(StageControls.glassShape(.cancel, reduceMotion: false) == stop)
        #expect(StageControls.glassShape(.finishing, reduceMotion: false) == stop)
        #expect(StageControls.glassShape(.stopTranscribing, reduceMotion: false) == stop)
        let others = [StageControls.Control.pause, .mark, .discard].map { StageControls.glassShape($0, reduceMotion: false) }
        #expect(Set(others).count == 3, "each of the other controls keeps a glass of its own")
        #expect(!others.contains(nil))
        #expect(!others.contains(stop))
    }

    @Test("a take that finishes in a moment keeps its Finishing pill up a little while, but nothing over a take that is over")
    func pillHolds() {
        #expect(StageControls.shownLayout(.stopTranscribing, holdingPill: true) == .finishing)
        #expect(StageControls.shownLayout(.stopTranscribing, holdingPill: false) == .stopTranscribing)
        #expect(StageControls.shownLayout(.finishing, holdingPill: true) == .finishing)
        #expect(StageControls.shownLayout(.none, holdingPill: true) == .none)
        #expect(StageControls.shownLayout(.bar, holdingPill: false) == .bar)
        #expect(StageControls.pillHold >= .milliseconds(450), "long enough for the fold to settle")
        #expect(StageControls.pillHold <= .seconds(1), "short enough that Stop Transcribing is there when it is wanted")
    }

    @MainActor
    @Test("under Reduce Motion no control's glass morphs, and the controls only crossfade")
    func controlsCrossfadeUnderReduceMotion() {
        let controls: [StageControls.Control] = [.pause, .mark, .stop, .cancel, .discard, .finishing, .stopTranscribing]
        let shapes = controls.map { StageControls.glassShape($0, reduceMotion: true) }
        #expect(shapes == Array(repeating: nil, count: controls.count))
        #expect(StageControls.layoutChange(reduceMotion: true) == DS.Motion.crossfade)
        #expect(StageControls.layoutChange(reduceMotion: false) == DS.Motion.controlsMorph)
    }

    @Test("the Stage hands its pieces on only while its take winds down, and nothing travels under Reduce Motion")
    func landingOffers() {
        #expect(!StageLanding.stageOffers(.arming(.countIn(remaining: 3))))
        #expect(!StageLanding.stageOffers(.recording))
        #expect(!StageLanding.stageOffers(.paused(since: Date())))
        #expect(!StageLanding.stageOffers(.failed(message: "The microphone stopped.")))
        #expect(StageLanding.stageOffers(.finishing))
        #expect(StageLanding.stageOffers(.transcribing(progress: 0.5)))
        #expect(StageLanding.stageOffers(.done(entryID: nil)))
        #expect(StageLanding.carries(eligible: true, reduceMotion: false))
        #expect(!StageLanding.carries(eligible: true, reduceMotion: true))
        #expect(!StageLanding.carries(eligible: false, reduceMotion: false))
    }

    @Test("the band and the time link across only while both sides carry them, each to its own place")
    func landingPieces() {
        for piece in [StageLanding.Piece.band, .time] {
            #expect(StageLanding.id(piece, on: .stage, carries: true) == StageLanding.id(piece, on: .transcript, carries: true))
            #expect(StageLanding.id(piece, on: .stage, carries: false) != StageLanding.id(piece, on: .transcript, carries: false))
            #expect(StageLanding.id(piece, on: .stage, carries: true) != StageLanding.id(piece, on: .transcript, carries: false))
        }
        #expect(StageLanding.id(.band, on: .stage, carries: true) != StageLanding.id(.time, on: .transcript, carries: true))
    }

    @Test("as a take lands, the Stage's words, facts and controls are gone before the transcript's words begin, all inside the landing")
    func landingWordsNeverOverlap() {
        #expect(StageLanding.wordsWait >= StageLanding.stageLeaves)
        #expect(StageLanding.wordsWait + StageLanding.wordsArrive <= 0.45)
        #expect(StageLanding.stageLeaves <= 0.2)
    }

    @Test("a Stage whose run lets go keeps its last words, and only a live one shows the quiet line")
    func teleprompterKeepsItsLastWords() {
        let last = StageTeleprompter.Words(settled: "the last words", partial: "")
        let none = StageTeleprompter.Words(settled: "", partial: "")
        let coming = StageTeleprompter.Words(settled: "more", partial: "words")
        #expect(StageTeleprompter.shown(none, last: last, isLive: false) == last)
        #expect(StageTeleprompter.shown(none, last: last, isLive: true) == nil)
        #expect(StageTeleprompter.shown(none, last: nil, isLive: false) == nil)
        #expect(StageTeleprompter.shown(coming, last: last, isLive: false) == coming)
    }

    @MainActor
    @Test("a Stage leaving as its take lands keeps showing its last words instead of the quiet line")
    func leavingStageKeepsItsWords() async {
        func prompter(_ words: String, isLive: Bool) -> some View {
            StageTeleprompter(
                settled: words, partial: "", quietLine: "Transcript appears here as it comes in", isLive: isLive, caretBlinks: true
            )
        }
        let host = NSHostingView(rootView: prompter("the last words of the take", isLive: true))
        let window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: 800, height: 200), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        await settle(for: .milliseconds(150))

        host.rootView = prompter("", isLive: false)
        await settle(for: .milliseconds(150))

        let words = HostedAccessibility.words(in: host)
        let kept = words.contains { $0.contains("the last words of the take") }
        #expect(kept)
        #expect(!words.contains("Transcript appears here as it comes in"))
    }

    @MainActor
    @Test("a live take's words cleared in the turn that ends it stay on its Stage, not the quiet line")
    func liveTakeKeepsItsWordsAsItEnds() async throws {
        let model = makeRecordingModel("stage-live-last-words")
        model.installTestTake(source: .microphone)
        let shown = try #require(model.recording)
        model.liveSegments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "the last words of the live take")]
        let hosted = HostedWindow(StageLiveText(isOnScreen: true).environment(model), width: 800, height: 200)
        defer { hosted.close() }
        await settle(for: .milliseconds(150))
        let before = HostedAccessibility.words(in: hosted.host)
        let showing = before.contains { $0.contains("the last words of the live take") }
        #expect(showing)
        #expect(shown.isStreaming, "a live take, whose Stage shows these words")

        model.liveSegments = []
        model.livePartialText = ""
        model.endTestTake()
        await settle(for: .milliseconds(150))

        let after = HostedAccessibility.words(in: hosted.host)
        let kept = after.contains { $0.contains("the last words of the live take") }
        #expect(kept)
        #expect(!after.contains("Your transcript appears here as you speak"))
    }

    @Test("a covered window, one on another Space or a minimized one stops the Stage drawing; any part in view keeps it going")
    func coveredWindowStopsDrawing() {
        #expect(WindowShownReader.shows(isVisible: true, isMiniaturized: false, occlusion: .visible))
        #expect(!WindowShownReader.shows(isVisible: true, isMiniaturized: false, occlusion: []))
        #expect(!WindowShownReader.shows(isVisible: true, isMiniaturized: true, occlusion: .visible))
        #expect(!WindowShownReader.shows(isVisible: false, isMiniaturized: false, occlusion: .visible))
    }

    @MainActor
    @Test("each clock character keeps its place counted from the right, so only the digits that change roll, briefly")
    func clockRollsByPlace() {
        #expect(StageClock.places("0:59").map(\.place) == [3, 2, 1, 0])
        #expect(StageClock.places("10:00").map(\.place) == [4, 3, 2, 1, 0])
        #expect(StageClock.places("1:00:00").map(\.character) == Array("1:00:00"))
        let units = StageClock.places("9:59").last
        let grown = StageClock.places("10:00").last
        #expect(units?.place == 0)
        #expect(grown?.place == 0, "the seconds keep their place as the clock grows a digit")
        #expect(StageClock.roll == .easeOut(duration: 0.2))
    }

    @Test("the entrance starts from 30 %, so its first frame is never an empty window")
    func entranceStartsInSight() {
        #expect(StagePage.entranceOpacity(entered: false) == 0.3)
        #expect(StagePage.entranceOpacity(entered: true) == 1)
    }

    @MainActor
    @Test("the media bar's time reads as one line, while the duration stands on its own for a landing take's clock")
    func timeReadoutReadsAsOne() {
        let model = makeRecordingModel("stage-time-readout")
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "x")], language: "en", modelName: "stub", durationSeconds: 280
        )
        let hosted = HostedWindow(PlaybackTimeLabel(scrubbingTo: 0).environment(model), width: 300, height: 40)
        defer { hosted.close() }
        let words = HostedAccessibility.words(in: hosted.host)
        #expect(words.contains("00:00 / 04:40"))
    }

    @MainActor
    @Test("under Reduce Motion the Stage only crossfades: a still dot, the band four times a second, no morph, nothing carried over")
    func reduceMotionOnlyCrossfades() {
        #expect(StagePage.entrance(reduceMotion: true) == DS.Motion.crossfade)
        #expect(StagePage.entranceScale(entered: false, reduceMotion: true) == 1)
        #expect(StagePage.controlsLift(entered: false, reduceMotion: true) == 0)
        #expect(StagePage.entranceScale(entered: false, reduceMotion: false) < 1, "with motion the page grows into place")
        #expect(StagePage.controlsLift(entered: false, reduceMotion: false) > 0)
        let origin = Date()
        #expect(RecDot.pulseOrigin(origin, reduceMotion: true) == nil)
        #expect(RecDot.pulseOrigin(origin, reduceMotion: false) == origin)
        #expect(RecDot.pulseOrigin(nil, reduceMotion: false) == nil)
        #expect(StageBand.cadence(reduceMotion: true) == .steps(every: 0.25))
        #expect(StageControls.layoutChange(reduceMotion: true) == DS.Motion.crossfade)
        let shapes = [StageControls.Control.stop, .finishing].map { StageControls.glassShape($0, reduceMotion: true) }
        #expect(shapes == [nil, nil])
        #expect(!StageLanding.carries(eligible: true, reduceMotion: true))
        #expect(ContentRoutes.routeAnimation(from: .stage, to: .phase, landing: true, reduceMotion: true) == DS.Motion.crossfade)
    }

    @MainActor
    @Test("only a take landing off its Stage takes the landing's time; leaving mid-take is the usual crossfade, and nothing fades into the Stage")
    func landingRouteAnimation() {
        #expect(ContentRoutes.routeAnimation(from: .stage, to: .phase, landing: true, reduceMotion: false) == DS.Motion.takeLanding)
        #expect(ContentRoutes.routeAnimation(from: .stage, to: .phase, landing: true, reduceMotion: true) == DS.Motion.crossfade)
        #expect(ContentRoutes.routeAnimation(from: .stage, to: .library, landing: false, reduceMotion: false) == DS.Motion.route)
        #expect(ContentRoutes.routeAnimation(from: .stage, to: .library, landing: false, reduceMotion: true) == nil)
        #expect(ContentRoutes.routeAnimation(from: .library, to: .stage, landing: false, reduceMotion: false) == nil)
        #expect(ContentRoutes.routeAnimation(from: .library, to: .statistics, landing: false, reduceMotion: false) == DS.Motion.route)
        #expect(ContentRoutes.routeAnimation(from: .library, to: .statistics, landing: false, reduceMotion: true) == nil)
    }

    @Test("Esc cancels a take that is still starting, except while the title field has the keyboard")
    func escapeLeavesTheTitleAlone() {
        #expect(StageControls.cancelShortcut(titleFocused: false) == .cancelAction)
        #expect(StageControls.cancelShortcut(titleFocused: true) == nil)
    }

    @MainActor
    @Test("the take's title field tells the model while it has the keyboard, and when it lets go")
    func titleFocusReachesTheModel() async throws {
        let model = makeRecordingModel("stage-title-focus")
        model.installTestTake(source: .microphone)
        defer { model.endTestTake() }
        let take = try #require(model.recording)
        let hosted = HostedWindow(TakeTitleField(take: take).environment(model), width: 300, height: 60)
        defer { hosted.close() }
        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField { return field }
            return view.subviews.lazy.compactMap(textField(in:)).first
        }
        let field = try #require(textField(in: hosted.host))

        hosted.window.makeFirstResponder(field)
        let focused = await waitUntil { model.takeTitleHasFocus }
        #expect(focused)

        hosted.window.makeFirstResponder(nil)
        let released = await waitUntil { !model.takeTitleHasFocus }
        #expect(released)
    }

    @Test("the facts line counts the run's progress, and says so while the engine prepares the audio")
    func transcribingLine() {
        #expect(StageFacts.transcribingLine(stage: .preparingAudio, progress: nil) == "Preparing audio…")
        #expect(StageFacts.transcribingLine(stage: nil, progress: nil) == "Transcribing…")
        #expect(StageFacts.transcribingLine(stage: .transcribing, progress: 0.42) == "Transcribing… · 42%")
        #expect(StageFacts.transcribingLine(stage: .preparingAudio, progress: 0.1) == "Transcribing… · 10%")
    }

    @Test("the facts line says how long the run has left once it can tell")
    func transcribingTimeLeft() {
        #expect(StageFacts.transcribingLine(stage: .transcribing, progress: 0.42, remaining: 725) == "Transcribing… · 42% · 12 min left")
        #expect(StageFacts.transcribingLine(stage: .transcribing, progress: 0.9, remaining: 38) == "Transcribing… · 90% · 38 s left")
        #expect(StageFacts.transcribingLine(stage: .transcribing, progress: 0.42, remaining: 2 * 3600 + 5 * 60) == "Transcribing… · 42% · 2 h 5 min left")
        #expect(StageFacts.transcribingLine(stage: .transcribing, progress: 0.42, remaining: nil) == "Transcribing… · 42%")
        #expect(StageFacts.transcribingLine(stage: .transcribing, progress: 1, remaining: 0) == "Transcribing… · 100%")
        #expect(StageFacts.transcribingLine(stage: nil, progress: nil, remaining: 60) == "Transcribing…", "no countdown without a percentage")
    }

    @Test("a stopped take's quiet line promises words as they come only from an engine that sends them")
    func takeQuietLine() {
        #expect(StageTakeText.quietLine(streamsPartials: true) == "Transcript appears here as it comes in")
        #expect(StageTakeText.quietLine(streamsPartials: false) == "Transcript appears when it's done")
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
        #expect(shown.utf8.count <= StageTakeText.recentBytes)
        #expect(shown.hasSuffix("word last"))
        #expect(shown.hasPrefix("word "), "the cut never starts mid-word")
    }

    @Test("text with no spaces, like Japanese, still shows its newest stretch, cut between characters")
    func takeTextWithoutSpaces() {
        let text = String(repeating: "日本語のテキスト", count: 500)
        let shown = StageTakeText.shown(text)
        #expect(!shown.isEmpty)
        #expect(shown.utf8.count <= StageTakeText.recentBytes)
        #expect(shown.utf8.count >= StageTakeText.recentBytes - StageTakeText.cutStep - 3)
        #expect(text.hasSuffix(shown))
    }

    @Test("the cut never splits a character built from several scalars, like a thumbs-up with a skin tone")
    func takeTextKeepsWholeCharacters() {
        let text = "x" + String(repeating: "👍🏽", count: 400)
        let shown = StageTakeText.shown(text)
        #expect(!shown.isEmpty)
        #expect(text.hasSuffix(shown))
    }

    @Test("a three-hour take's text costs a partial no more than the stretch it shows")
    func takeTextCostsItsTail() {
        let hours = String(repeating: "perché è già città, ", count: 7_500)
        // This thread's CPU time, not wall time, so a starved scheduler can't fail it.
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var laidOut = 0
        for _ in 0..<200 { laidOut += StageTakeText.shown(hours).utf8.count }
        let cpuNanoseconds = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
        #expect(cpuNanoseconds < 20_000_000, "\(cpuNanoseconds / 1_000_000) ms of CPU")
        #expect(laidOut <= 200 * StageTakeText.recentBytes)
    }

    @Test("words arriving at the end leave the start of the shown text where it was, until a whole step has come in")
    func takeTextCutMovesInSteps() {
        var text = String(repeating: "steady words ", count: 120)
        let first = StageTakeText.shown(text)
        var cuts = 0
        var previous = first
        for index in 0..<40 {
            text += "w\(index) "
            let shown = StageTakeText.shown(text)
            if !shown.hasPrefix(previous.trimmingCharacters(in: .whitespaces)) { cuts += 1 }
            #expect(shown.utf8.count <= StageTakeText.recentBytes)
            #expect(shown.utf8.count >= StageTakeText.recentBytes - StageTakeText.cutStep - 20, "still enough to fill the column")
            previous = shown
        }
        #expect(cuts <= 1, "about 160 characters of new words move the cut once at most")
        #expect(StageTakeText.shown(text).hasSuffix("w39 "))
    }

    @MainActor
    @Test("a failed take offers Reveal in Finder once its failure saved the audio, and its band greys")
    func failedTakeLook() {
        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture
        )
        #expect(!StageBand.greys(take.state))
        take.fail("Nothing was recorded.")
        #expect(StageBand.greys(take.state))
        #expect(!ErrorBanner.revealsTakeInFinder(take), "nothing was recorded, so there is nothing to reveal")
        take.failure = RecordingSession.Failure(
            audioURL: URL(fileURLWithPath: "/tmp/parola-stage-failed.wav"),
            save: Task<LibraryEntry, any Error> { throw CancellationError() },
            recovery: nil, title: "R", category: .transcription, source: .microphone, annotations: AppModel.TakeAnnotations()
        )
        #expect(ErrorBanner.revealsTakeInFinder(take))
    }

    @MainActor
    private func stage(_ take: RecordingSession, model: AppModel) -> (window: CGRect, elements: [HostedAccessibility.Element]) {
        // The window's route is the Stage's, as it is whenever a Stage is on screen; any other route means the page is on its way out.
        model.route = .recording
        let hosted = HostedWindow(StagePage(take: take).environment(model), width: 1180, height: 708)
        defer { hosted.close() }
        return (hosted.window.frame, HostedAccessibility.elements(in: hosted.host))
    }

    @MainActor
    private func liveTake() -> RecordingSession {
        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture
        )
        _ = take.markCapturing(at: Date(timeIntervalSinceNow: -60))
        return take
    }

    @MainActor
    @Test("a failed take's Stage keeps the clock and the band where they were, with the banner under the band")
    func failedStageHoldsItsPlace() throws {
        let model = makeRecordingModel("stage-failed-layout")
        let live = liveTake()
        var failed = live
        failed.fail("Nothing was recorded.")

        let before = stage(live, model: model)
        let after = stage(failed, model: model)

        let clockBefore = before.elements.first { $0.label == "Recording time" }
        let clockAfter = after.elements.first { $0.label == "Recording time" }
        let bandBefore = before.elements.first { $0.label == "Input level" }
        let bandAfter = after.elements.first { $0.label == "Input level" }
        let banner = after.elements.first { $0.words.contains("Something went wrong") }
        let clockWas = try #require(clockBefore).frame
        let clockIs = try #require(clockAfter).frame
        let bandWas = try #require(bandBefore).frame
        let bandIs = try #require(bandAfter).frame
        let bannerIs = try #require(banner).frame
        #expect(abs(clockIs.midY - clockWas.midY) < 1, "the clock stays put")
        #expect(abs(bandIs.midY - bandWas.midY) < 1, "the band stays put")
        #expect(bannerIs.minY > bandIs.maxY || bannerIs.maxY < bandIs.minY, "the banner sits clear of the band")
    }

    @MainActor
    @Test("a failed take's banner reveals its entry under the one Reveal in Finder the app uses")
    func failedBannerRevealsInFinder() throws {
        let model = makeRecordingModel("stage-failed-reveal")
        var failed = liveTake()
        failed.fail("The model stopped answering.")
        failed.failure = RecordingSession.Failure(
            audioURL: URL(fileURLWithPath: "/tmp/parola-stage-reveal.wav"),
            save: Task<LibraryEntry, any Error> { throw CancellationError() },
            recovery: nil, title: "R", category: .transcription, source: .microphone, annotations: AppModel.TakeAnnotations()
        )

        let hosted = stage(failed, model: model)

        let reveal = hosted.elements.first { $0.identifier?.hasSuffix("Error.Button.RevealInFinder") == true }
        let button = try #require(reveal)
        #expect(button.words.contains("Reveal in Finder"))
        let showWords = hosted.elements.filter { $0.words.contains("Show in Finder") }
        #expect(showWords.isEmpty)
    }

    @MainActor
    @Test("the Finishing pill reads as words, not as a dimmed button")
    func finishingPillIsALabel() throws {
        let model = makeRecordingModel("stage-finishing-label")
        var take = liveTake()
        _ = take.finish(at: Date())

        let hosted = stage(take, model: model)

        let pill = hosted.elements.first { $0.identifier?.hasSuffix("Stage.Label.Finishing") == true }
        let found = try #require(pill)
        let enabled = found.object.responds(to: NSSelectorFromString("isAccessibilityEnabled"))
            ? found.object.value(forKey: "accessibilityEnabled") as? Bool : nil
        #expect(enabled == true, "a disabled control is read as dimmed")
        #expect(found.words.contains("Finishing the recording"))
    }

    @MainActor
    @Test("a take that passes through finishing in a moment holds its Finishing pill on the model's clock, then shows Stop Transcribing")
    func pillHoldsOnScreen() async throws {
        let clock = HeldClock()
        let model = makeRecordingModel("stage-pill-hold", clock: clock)
        func controls(_ take: RecordingSession) -> some View {
            StageControls(take: take).environment(model)
        }
        var take = liveTake()
        let host = NSHostingView(rootView: controls(take))
        let window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: 900, height: 120), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        await settle(for: .milliseconds(100))
        func shows(_ id: String) -> Bool {
            HostedAccessibility.elements(in: host).contains { $0.identifier?.hasSuffix(id) == true }
        }

        _ = take.finish(at: Date())
        host.rootView = controls(take)
        await settle(for: .milliseconds(50))
        _ = take.transcribing(progress: nil)
        host.rootView = controls(take)
        let holding = await waitUntil { clock.asked.withLock { $0 }.contains(StageControls.pillHold) }
        #expect(holding)
        await settle(for: .milliseconds(50))

        #expect(shows("Stage.Label.Finishing"))
        #expect(!shows("Stage.Button.StopTranscribing"))
        await clock.gate.open()
        let replaced = await waitUntil(timeoutMs: 3_000) { shows("Stage.Button.StopTranscribing") }
        #expect(replaced)
    }

    @MainActor
    @Test("a failed take's Stage says it stopped, not that it records")
    func failedStageSaysStopped() {
        let model = makeRecordingModel("stage-failed-status")
        var failed = liveTake()
        failed.fail("The model stopped answering.")

        let hosted = stage(failed, model: model)

        let words = hosted.elements.flatMap(\.words)
        #expect(words.contains("STOPPED"))
        #expect(!words.contains("REC"))
    }

    @MainActor
    @Test("a transcribing take's overview keeps the page's margins")
    func overviewMargins() throws {
        let model = makeRecordingModel("stage-overview-margins")
        var take = liveTake()
        _ = take.finish(at: Date())
        _ = take.transcribing(progress: 0.4)

        let hosted = stage(take, model: model)

        let overview = hosted.elements.first { $0.label == "Transcription progress" }
        let frame = try #require(overview).frame
        #expect(frame.minX - hosted.window.minX >= DS.Spacing.large - 0.5)
        #expect(hosted.window.maxX - frame.maxX >= DS.Spacing.large - 0.5)
    }

    @MainActor
    @Test("a transcript past the inline cap is copied with the same paragraphs and speaker names")
    func longCopyKeepsParagraphs() async {
        let model = makeRecordingModel("stage-long-copy")
        let segments = (0..<(TranscriptDerive.synchronousCap + 50)).map { index in
            TranscriptSegment(
                id: index, start: Double(index) * 3, end: Double(index) * 3 + 1, text: "Line \(index).",
                speaker: index.isMultiple(of: 2) ? "Alice" : "Bob"
            )
        }
        let transcript = Transcript(segments: segments, language: "en", modelName: "stub")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("stage-long-copy-\(UUID())"))

        await model.copyTranscriptAsPlainText(transcript, to: pasteboard)

        let expected = TranscriptParagraphs.plainText(segments: segments, includeSpeakerLabels: true)
        #expect(pasteboard.string(forType: .string) == expected)
        #expect(expected.hasPrefix("Alice\nLine 0.\n\nBob\nLine 1."))
    }

    @MainActor
    @Test("the saved toast names the place the take went, and stays five seconds")
    func toast() {
        #expect(TakeSavedToast.message(category: .meeting) == "Saved to Meetings")
        #expect(TakeSavedToast.message(category: .transcription) == "Saved to Transcriptions")
        #expect(TakeSavedNotice.lifetime == .seconds(5))
    }

    @MainActor
    @Test("the Stage's state words have their Italian")
    func italian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(StageTimeSlot.preparingText(name: "openai_whisper-large-v3_turbo", download: 0.42, bundle: it)
            == "Preparazione di Whisper Turbo · 42%")
        #expect(StageFacts.transcribingLine(stage: .preparingAudio, progress: nil, bundle: it) == "Preparazione dell'audio…")
        #expect(TakeSavedToast.message(category: .meeting, bundle: it) == "Salvata in Riunioni")
        #expect(TakeSavedToast.message(category: .transcription, bundle: it) == "Salvata in Trascrizioni")
        #expect(String(localized: "PAUSED", bundle: it) == "IN PAUSA")
        #expect(String(localized: "Finishing…", bundle: it) == "Chiusura in corso…")
        #expect(String(localized: "Finishing the recording", bundle: it) == "Chiusura della registrazione in corso")
        #expect(String(localized: "Cancel Recording", bundle: it) == "Annulla registrazione")
        #expect(String(localized: "Transcript appears here as it comes in", bundle: it) == "La trascrizione appare qui man mano che arriva")
        #expect(String(localized: "Reveal in Finder", bundle: it) == "Mostra nel Finder")
        #expect(String(localized: "This recording was deleted. Restore it from Recently Deleted to try again.", bundle: it)
            == "Questa registrazione è stata eliminata. Ripristinala da Eliminati di recente per riprovare.")
        #expect(String(localized: "The recording stopped", bundle: it) == "La registrazione si è interrotta")
        #expect(String(localized: "STOPPED", bundle: it) == "FERMATA")
        #expect(String(localized: "Transcript appears when it's done", bundle: it) == "La trascrizione appare quando è pronta")
    }

    @MainActor
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

        @Test("the transcript a take lands as takes the Stage's pieces through its save, and lets go once a new take starts")
        func landingTranscriptIsTheTake() async throws {
            let audio = try makeTakeWAV("stage-landing-gate", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "landed words")])
                let model = makeModel("stage-landing-gate")
                let before = StageLanding.transcriptIsTheTake(model)
                #expect(!before)
                let save = FetchGate()
                model.beforeLandingSave = { await save.wait() }

                recordAndStop(model, audio: audio, seconds: 1)

                let onScreen = await waitUntil { model.route == .transcript && model.transcript != nil }
                #expect(onScreen)
                let unsaved = model.recording?.isTranscribing == true
                #expect(unsaved, "the save is still held")
                let atLanding = StageLanding.transcriptIsTheTake(model)
                #expect(atLanding, "over its working file before the save lands")
                #expect(model.routeLandsTake, "the change off the Stage was the take's own landing")
                await save.open()
                let landed = await landedEntry(model)
                let entry = try #require(landed)
                let moved = await waitUntil { model.recording?.state == .done(entryID: entry.id) && model.sourceFileURL != audio }
                #expect(moved, "the save moved playback onto the entry's own audio")
                let afterSave = StageLanding.transcriptIsTheTake(model)
                #expect(afterSave, "as its entry once the save lands")
                model.route = .statistics
                #expect(!model.routeLandsTake, "the next route change is no landing")
                #expect(StageLanding.stageIsLeaving(model), "a page picked as the take lands keeps its Stage gone")

                model.installTestTake(source: .microphone)
                let newTake = StageLanding.transcriptIsTheTake(model)
                #expect(!newTake)
                model.endTestTake()
            }
        }

        @Test("leaving a recording take's Stage for another page is no landing")
        func leavingMidTakeIsNoLanding() {
            let model = makeModel("stage-leave-mid-take")
            model.installTestTake(source: .microphone)
            #expect(model.route == .recording)

            model.route = .transcript

            #expect(!model.routeLandsTake)
            #expect(StageLanding.stageIsLeaving(model), "its words and controls still go first")
            model.endTestTake()
        }

        @Test("a live take that lands on its Stage carries its band and time into its transcript, over its own audio and then as its entry")
        func liveTakeLandingCarries() async throws {
            let audio = try makeTakeWAV("stage-live-landing", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the live words")],
                    partials: ["the", "the live", "the live words"],
                    delayMs: 300,
                    recordedAudio: audio
                ))
                let model = makeModel("stage-live-landing")
                model.useStreaming = true
                let save = FetchGate()
                model.beforeLandingSave = { await save.wait() }
                model.startRecording(source: .microphone)
                let recording = await waitUntil(timeoutMs: 30_000) { model.recording?.state == .recording }
                #expect(recording)

                model.stopRecordingAndTranscribe()

                let landed = await waitUntil(timeoutMs: 10_000) {
                    model.recording?.state == .done(entryID: nil) && model.route == .transcript
                }
                #expect(landed)
                let stageOffers = model.recording.map { StageLanding.stageOffers($0.state) } == true
                #expect(stageOffers, "the Stage it leaves still offers its pieces")
                let atLanding = StageLanding.transcriptIsTheTake(model)
                #expect(atLanding, "over its own audio before the save lands")
                #expect(model.routeLandsTake)
                #expect(model.player != nil, "the media bar the band drops into is there")
                await save.open()
                let saved = await landedEntry(model, timeoutMs: 10_000)
                let entry = try #require(saved)
                let settled = await waitUntil { model.recording?.state == .done(entryID: entry.id) }
                #expect(settled)
                let afterSave = StageLanding.transcriptIsTheTake(model)
                #expect(afterSave, "as its entry once the save lands")
            }
        }

        @Test("a live take's Stage keeps the last words it drew as it lands, however fast its closing words came in")
        func liveLandingKeepsTheLastWordsDrawn() async throws {
            let lines = (1...11).map { "Line \($0) of the take." } + ["And the last words of all."]
            let words = lines.joined(separator: " ").split(separator: " ").map(String.init)
            // Rounds, because how many of the closing words one frame takes in varies from run to run.
            for round in 0..<3 {
                let audio = try makeTakeWAV("stage-live-burst-\(round)", seconds: 1)
                defer { try? FileManager.default.removeItem(at: audio) }
                try await withMocksCleared([.audioSource, .streaming]) {
                    await MockAudioSourceRegistry.shared.clear()
                    MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                        segments: lines.enumerated().map { index, text in
                            TranscriptSegmentSeed(start: Double(index), end: Double(index) + 0.9, text: text)
                        },
                        partials: stride(from: 2, through: words.count, by: 2).map { words.prefix($0).joined(separator: " ") },
                        delayMs: 600,
                        recordedAudio: audio
                    ))
                    let model = makeModel("stage-live-burst-\(round)")
                    model.useStreaming = true
                    let hosted = HostedWindow(StageLiveText(isOnScreen: true).environment(model), width: 800, height: 220)
                    defer { hosted.close() }
                    model.startRecording(source: .microphone)
                    let allIn = await waitUntil(timeoutMs: 30_000) { model.liveSegments.count == lines.count }
                    #expect(allIn)
                    await settle(for: .milliseconds(300))

                    model.stopRecordingAndTranscribe()

                    let landed = await waitUntil(timeoutMs: 10_000) { model.route == .transcript && model.recording?.isOver == true }
                    #expect(landed)
                    await settle(for: .milliseconds(150))
                    let shown = HostedAccessibility.words(in: hosted.host)
                    let kept = shown.contains { $0.contains("And the last words of all.") }
                    #expect(kept, "round \(round)")
                    _ = await landedEntry(model, timeoutMs: 10_000)
                }
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

        @Test("a take whose transcription fails keeps its Stage, with Retry and Reveal in Finder on the entry it saved")
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
                #expect(ErrorBanner.revealsTakeInFinder(take))
                let failure = try #require(take.failure)
                let landed = await landedEntry(model)
                let entry = try #require(landed)
                #expect(entry.title.hasSuffix("(transcription failed)"))
                let reveal = await model.takeReveal(for: failure)
                #expect(reveal == .reveal(entry.bundleURL), "Finder selects the entry, as a library row does")

                try await model.library.delete(entry.id)
                let deleted = await model.takeReveal(for: failure)
                #expect(deleted == .deleted(restorable: true))
                let restorable = AppModel.deletedTakeNotice(restorable: true).message
                let purged = AppModel.deletedTakeNotice(restorable: false).message
                #expect(restorable == "This recording was deleted. Restore it from Recently Deleted to try again.")
                #expect(purged == "This recording was deleted.")

                model.dismissTakeFailure()
                #expect(model.recording == nil)
                #expect(model.route != .recording)
            }
        }

        @Test("a take that lands on its Stage says where it went, and Copy pastes it as Copy Transcript does")
        func landingSaysWhereItWent() async throws {
            let audio = try makeTakeWAV("stage-saved", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(segments: [
                    TranscriptSegmentSeed(start: 0, end: 1, text: "Hello there.", speaker: "Alice"),
                    TranscriptSegmentSeed(start: 1.2, end: 2, text: "Still me.", speaker: "Alice"),
                    TranscriptSegmentSeed(start: 4, end: 5, text: "After a pause.", speaker: "Alice"),
                    TranscriptSegmentSeed(start: 5.2, end: 6, text: "Bob here.", speaker: "Bob"),
                ]))
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
                let pasted = pasteboard.string(forType: .string)
                #expect(pasted == "Alice\nHello there. Still me.\n\nAfter a pause.\n\nBob\nBob here.")
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
            model.route = .statistics

            model.summarizeSavedTake(entry.id)

            let summarized = await waitUntil { model.transcript?.summary?.text == "the gist" }
            #expect(summarized)
            #expect(model.route == .transcript, "the summary is written where it can be seen")
            #expect(model.transcriptPaneMode == .summary)
            #expect(model.takeSavedNotice == nil)
        }

        enum FinishingCancel: String, CaseIterable, Sendable {
            case cancel
            case bridgeCancel
            case cancelAllTasks
        }

        /// A live take whose final decode runs on for about a second and a half after Stop.
        private func startLiveTake(_ model: AppModel) async -> Bool {
            MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the live words")],
                partials: ["the", "the live", "the live words", "the live words", "the live words"],
                delayMs: 2_000
            ))
            model.useStreaming = true
            model.startRecording(source: .microphone)
            // The take records until Stop, so a loaded run's slow start hops can take their time.
            return await waitUntil(timeoutMs: 30_000) { model.recording?.state == .recording }
        }

        /// What the user gave the take before Stop: a title of their own, the Meeting category and one marker.
        private func annotate(_ model: AppModel) -> TimeInterval? {
            model.renameTake("Board review")
            model.setTakeCategory(.meeting)
            return model.addTakeMarker()
        }

        private func expectAnnotated(_ entry: LibraryEntry, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(entry.title == "Board review", sourceLocation: sourceLocation)
            #expect(entry.category == .meeting, sourceLocation: sourceLocation)
            #expect(entry.manifest.takeMarkers?.count == 1, sourceLocation: sourceLocation)
        }

        private func cancel(_ path: FinishingCancel, _ model: AppModel, server: ParolaAutomationServer) async throws {
            switch path {
            case .cancel:
                model.cancelCurrentWork()
            case .bridgeCancel:
                let commands = Dictionary(uniqueKeysWithValues: server.coreCommands().map { ($0.name, $0) })
                let command = try #require(commands["cancel"])
                _ = try await command.handler(try command.validate(AutomationArgs([:])), AutomationContext(model: model, server: server))
            case .cancelAllTasks:
                model.cancelAllTasks()
            }
        }

        @Test("a live take cancelled while it finishes still lands its words, and Record is free at once", arguments: FinishingCancel.allCases)
        func liveTakeFinishesAfterCancel(_ path: FinishingCancel) async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel("stage-live-cancel-\(path.rawValue)")
                let server = try ParolaAutomationServer(model: model)
                let recording = await startLiveTake(model)
                #expect(recording)
                let mark = annotate(model)
                #expect(mark != nil)
                model.stopRecordingAndTranscribe()
                #expect(model.recording?.state == .finishing)

                try await cancel(path, model, server: server)

                #expect(!model.recordingActive, "the finishing take doesn't hold up the next one")
                #expect(model.recording?.isOver == false, "the take lands only once its save does")
                #expect(model.hasPendingTakeWork, "a quit waits for its words")
                let landed = await landedEntry(model, timeoutMs: 10_000)
                let entry = try #require(landed)
                let document = try await model.library.load(entry.id).document
                #expect(document.transcript.text == "the live words")
                expectAnnotated(entry)
                let settled = await waitUntil { model.recording?.state == .done(entryID: entry.id) }
                #expect(settled)
                withExtendedLifetime(server) {}
            }
        }

        @Test("a live take let go by Cancel still lands when the next take starts at once, and leaves that take recording")
        func liveTakeFinishesBehindTheNextTake() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel("stage-live-cancel-next")
                let first = await startLiveTake(model)
                #expect(first)
                let mark = annotate(model)
                #expect(mark != nil)
                model.stopRecordingAndTranscribe()
                model.cancelCurrentWork()

                let second = await startLiveTake(model)
                #expect(second)
                let secondTake = model.recording?.takeID
                let landed = await landedEntry(model, timeoutMs: 10_000)
                let entry = try #require(landed)
                let document = try await model.library.load(entry.id).document
                #expect(document.transcript.text == "the live words")
                expectAnnotated(entry)
                #expect(model.recording?.takeID == secondTake)
                #expect(model.recording?.state == .recording, "the first take's landing leaves the second one alone")
                #expect(model.recordingWatchTask != nil, "the second take keeps its disk and checkpoint watch")
                #expect(model.route == .recording)
                model.cancelCurrentWork()
            }
        }

        @Test("a live take let go by Cancel whose stream fails says so rather than waiting for words that never come")
        func letGoLiveTakeThatFailsSaysSo() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    partials: ["the", "the live"], delayMs: 1_000,
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "the decoder gave up")
                ))
                let model = makeModel("stage-live-cancel-fails")
                model.useStreaming = true
                model.startRecording(source: .microphone)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                model.stopRecordingAndTranscribe()
                model.cancelCurrentWork()

                let message = AppModel.streamEndedWithoutTranscriptMessage()
                let failed = await waitUntil { model.recording?.state == .failed(message: message) }
                #expect(failed)
                let notice = await waitForNotice(model)
                #expect(notice?.message == message)
                let settled = await waitUntil { !model.hasPendingTakeWork }
                #expect(settled)
            }
        }

        @Test("after Stop and Cancel the sidebar comes back at once, while the take still saves")
        func sidebarReturnsAfterCancel() async throws {
            let audio = try makeTakeWAV("stage-cancel-sidebar", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let model = makeModel("stage-cancel-sidebar")
            let capture = HeldCutShortCapture(file: audio)
            model.takeCaptureOverride = { _ in capture }
            model.mainSidebar.userSet(.all)
            let release = HostedWindow(Color.clear.modifier(TakeSidebarRelease()).environment(model))
            defer { release.close() }
            model.startRecording(source: .microphone)
            let up = await waitUntil { model.liveSource != nil }
            #expect(up)
            model.mainSidebar.hold(true, animation: nil)
            #expect(model.mainSidebar.visibility == .detailOnly)
            model.stopRecordingAndTranscribe()

            model.cancelCurrentWork()

            let returned = await waitUntil { model.mainSidebar.visibility == .all }
            #expect(returned)
            #expect(model.recording?.isTranscribing == true, "the take is still saving")
            await capture.letGo()
            let over = await waitUntil { model.recording?.isOver == true }
            #expect(over)
        }

        @Test("a sidebar opened while the take transcribes on its Stage stays open through a trip to another page and back")
        func sidebarOpenedWhileTranscribingStaysOpen() async throws {
            let audio = try makeTakeWAV("stage-transcribing-sidebar", seconds: 2)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "words")], partials: ["some", "some words"], gate: gate)
                let model = makeModel("stage-transcribing-sidebar")
                let routes = HostedWindow(ContentRoutes().modifier(TakeSidebarRelease()).environment(model))
                defer { routes.close() }
                recordAndStop(model, audio: audio, seconds: 2)
                let streamed = await waitUntil { model.takePartialText == "some words" }
                #expect(streamed)
                let folded = await waitUntil { model.mainSidebar.visibility == .detailOnly }
                #expect(folded)

                model.mainSidebar.userSet(.all)
                model.route = .statistics
                await settle(for: .milliseconds(300))
                _ = model.showStage()
                await settle(for: .milliseconds(400))

                #expect(model.route == .recording)
                #expect(model.recording?.isTranscribing == true)
                #expect(model.mainSidebar.visibility == .all, "the Stage folded the sidebar the user opened")
                model.stopTranscribingTake()
                await gate.open()
                let settled = await waitUntil(timeoutMs: 10_000) { !model.hasPendingTakeWork }
                #expect(settled)
            }
        }

        @Test("the saved toast goes on its own once its window has shown it, and not before")
        func savedToastExpires() async {
            let model = makeModel("stage-saved-expiry")
            model.takeSavedLifetime = .milliseconds(50)
            model.mainWindowPresenceOverride = .hidden

            model.takeSavedNotice = TakeSavedNotice(entryID: "E", category: .meeting)
            await settle(for: .milliseconds(500))
            #expect(model.takeSavedNotice != nil, "the toast went while its window was out of sight")

            model.takeSavedCameOnScreen()
            let gone = await waitUntil { model.takeSavedNotice == nil }
            #expect(gone)
        }

        @Test("the saved toast's window coming on screen is what starts its time")
        func savedToastStartsWhenShown() async throws {
            let model = makeModel("stage-saved-shown")
            model.takeSavedLifetime = .milliseconds(50)
            let notice = TakeSavedNotice(entryID: "E", category: .transcription)
            model.takeSavedNotice = notice
            let hosted = HostedWindow(TakeSavedToast(notice: notice).environment(model), width: 600, height: 120)
            defer { hosted.close() }
            func reader(in view: NSView) -> WindowShownReader.ReaderView? {
                view as? WindowShownReader.ReaderView ?? view.subviews.lazy.compactMap(reader(in:)).first
            }
            let found = reader(in: hosted.host)
            let shown = try #require(found)
            hosted.window.orderOut(nil)
            shown.onChange?(false)
            await settle(for: .milliseconds(400))
            #expect(model.takeSavedNotice == notice)

            shown.onChange?(true)

            let gone = await waitUntil { model.takeSavedNotice == nil }
            #expect(gone)
        }

        @Test("a hold whose pointer exit never came ends with its toast, so the next toast still goes on its own")
        func savedToastHoldEndsWithIt() async {
            let model = makeModel("stage-saved-hold-ends")
            model.takeSavedLifetime = .milliseconds(50)
            model.takeSavedNotice = TakeSavedNotice(entryID: "E", category: .transcription)
            model.takeSavedCameOnScreen()
            model.holdTakeSaved(true)
            model.dismissTakeSaved()

            model.takeSavedNotice = TakeSavedNotice(entryID: "F", category: .transcription)
            model.takeSavedCameOnScreen()

            let gone = await waitUntil { model.takeSavedNotice == nil }
            #expect(gone)
        }

        @Test("the pointer resting on the saved toast holds it, and leaving starts its time again")
        func savedToastHoldsUnderThePointer() async {
            let model = makeModel("stage-saved-hover")
            model.takeSavedLifetime = .milliseconds(100)
            model.takeSavedNotice = TakeSavedNotice(entryID: "E", category: .transcription)
            model.takeSavedCameOnScreen()

            model.holdTakeSaved(true)
            await settle(for: .milliseconds(400))
            #expect(model.takeSavedNotice != nil)

            model.holdTakeSaved(false)
            let gone = await waitUntil { model.takeSavedNotice == nil }
            #expect(gone)
        }

        @Test("a new take takes the saved toast down, so it never sits on that take's Stage")
        func newTakeClearsTheSavedToast() {
            let model = makeModel("stage-saved-new-take")
            model.takeSavedNotice = TakeSavedNotice(entryID: "E", category: .transcription)

            model.installTestTake(source: .microphone)

            #expect(model.takeSavedNotice == nil)
            model.endTestTake()
        }

        @Test("a take started from a failed take's Stage folds the sidebar and enters as any new take does")
        func newTakeOnAFailedStageFolds() async throws {
            let model = makeModel("stage-refold")
            model.mainSidebar.userSet(.all)
            model.recordingCountInSeconds = 60
            model.startRecording(source: .microphone)
            let routes = HostedWindow(ContentRoutes().modifier(TakeSidebarRelease()).environment(model))
            defer { routes.close() }
            let folded = await waitUntil { model.mainSidebar.visibility == .detailOnly }
            #expect(folded)
            model.failCountIn("Parola can't use the microphone.")
            let released = await waitUntil { model.mainSidebar.visibility == .all }
            #expect(released)
            #expect(model.route == .recording, "the failed take keeps its Stage")

            model.installTestTake(source: .microphone)

            let refolded = await waitUntil { model.mainSidebar.visibility == .detailOnly }
            #expect(refolded)
            model.endTestTake()
        }

        @Test("a count-in hands its Stage to its take without building the page again")
        func countInKeepsItsStage() async throws {
            let audio = try makeTakeWAV("stage-count-in-handover", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            let model = makeModel("stage-count-in-handover")
            let capture = HeldCutShortCapture(file: audio)
            model.takeCaptureOverride = { _ in capture }
            model.recordingCountInSeconds = 1
            let routes = HostedWindow(ContentRoutes().environment(model))
            defer { routes.close() }
            func readers(in view: NSView) -> [NSView] {
                (view is WindowShownReader.ReaderView ? [view] : []) + view.subviews.flatMap(readers(in:))
            }
            model.startRecording(source: .microphone)
            let counting = await waitUntil { model.recordingCountdown != nil }
            #expect(counting)
            await settle(for: .milliseconds(300))
            let before = readers(in: routes.host)

            let handedOver = await waitUntil(timeoutMs: 10_000) { model.liveSource != nil }
            #expect(handedOver)
            await settle(for: .milliseconds(400))
            let after = readers(in: routes.host)

            #expect(before.count == 1)
            #expect(after.count == 1)
            let samePage = before.first.map { page in after.first === page } ?? false
            #expect(samePage, "the take keeps its count-in's Stage, so its entrance doesn't play twice")
            model.cancelCurrentWork()
        }

        @Test("resetTestState waits for a let-go take's save, so the library it wipes stays empty")
        func resetWaitsForALetGoTake() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel("stage-live-reset")
                let server = try ParolaAutomationServer(model: model)
                let context = AutomationContext(model: model, server: server)
                let lifecycle = Dictionary(uniqueKeysWithValues: server.lifecycleCommands().map { ($0.name, $0) })
                let reset = try #require(lifecycle["resetTestState"])
                let arguments = try reset.validate(AutomationArgs([:]))
                let recording = await startLiveTake(model)
                #expect(recording)
                model.beforeLandingSave = { try await Task.sleep(for: .milliseconds(300)) }
                model.stopRecordingAndTranscribe()

                _ = try await reset.handler(arguments, context)

                #expect(!model.hasPendingTakeWork, "the reset wiped the library with the take still saving")
                let quiet = await waitUntil(timeoutMs: 10_000) { !model.hasPendingTakeWork }
                #expect(quiet)
                let entries = await model.library.list()
                #expect(entries.isEmpty, "the take's save landed in the wiped library")
                withExtendedLifetime(server) {}
            }
        }

        @Test("a live take let go with nothing in it says so rather than staying on transcribing")
        func emptyLetGoTakeSettles() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["a", "b", "c"], delayMs: 1_500))
                let model = makeModel("stage-cancel-empty")
                model.useStreaming = true
                model.startRecording(source: .microphone)
                let recording = await waitUntil(timeoutMs: 30_000) { model.recording?.state == .recording }
                #expect(recording)
                model.stopRecordingAndTranscribe()

                model.cancelCurrentWork()

                let settled = await waitUntil(timeoutMs: 10_000) { !model.hasPendingTakeWork }
                #expect(settled)
                let message = AppModel.nothingRecordedMessage()
                let failed = await waitUntil { model.recording?.state == .failed(message: message) }
                #expect(failed)
                #expect(model.exportNotice?.message == message, "Cancel left the Stage, so a notice says it")
                let entries = await model.library.list()
                #expect(entries.isEmpty)
            }
        }

        @Test("a Cancel while a take's own words are landing leaves it landing, its checkpoint held until the save")
        func cancelDuringTheLanding() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["the", "the live"], delayMs: 200))
                let model = makeModel("stage-cancel-landing")
                model.useStreaming = true
                model.startRecording(source: .microphone)
                let recording = await waitUntil(timeoutMs: 30_000) { model.recording?.state == .recording }
                #expect(recording)
                let take = try #require(model.activeTake)
                let recovery = try #require(take.recovery)
                let real = model.streamingConsumer
                real?.cancel()
                await real?.value
                let deliver = FetchGate()
                let session = HeldLandingSession()
                let words = Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "the live words")], language: "en", modelName: "stub"
                )
                model.streamingConsumer = Task { @MainActor in
                    await deliver.wait()
                    await model.handleStreamingEvent(.finished(words), take: take, session: session)
                }
                let save = FetchGate()
                model.beforeLandingSave = { await save.wait() }
                model.stopRecordingAndTranscribe()
                await deliver.open()
                let landing = await waitUntil { await session.entered }
                #expect(landing)

                model.cancelCurrentWork()
                await session.release()

                let finished = await waitUntil { model.streamingConsumer == nil && model.recording?.isTranscribing == true }
                #expect(finished)
                await settle(for: .milliseconds(300))
                let message = AppModel.streamEndedWithoutTranscriptMessage()
                #expect(model.recording?.state != .failed(message: message), "the take was landing, not lost")
                #expect(model.exportNotice?.message != message)
                #expect(model.recoveryHeldByTake.contains(recovery), "its checkpoint stays until the save lands")
                await save.open()
                let landed = await landedEntry(model)
                let entry = try #require(landed)
                let settled = await waitUntil { model.recording?.state == .done(entryID: entry.id) }
                #expect(settled)
            }
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
