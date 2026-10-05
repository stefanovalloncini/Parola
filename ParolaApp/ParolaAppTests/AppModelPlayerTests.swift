import Foundation
import Testing
import AVFoundation
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("AppModel player")
struct AppModelPlayerTests {

    private static func makeSegments(_ pairs: [(id: Int, start: Double, end: Double)]) -> [TranscriptSegment] {
        pairs.map { TranscriptSegment(id: $0.id, start: $0.start, end: $0.end, text: "seg-\($0.id)") }
    }

    private static func makeTranscript(_ pairs: [(id: Int, start: Double, end: Double)]) -> Transcript {
        Transcript(segments: makeSegments(pairs), language: "en", modelName: "stub")
    }

    private static func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelPlayerTests-\(UUID().uuidString).m4a")
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
    }

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("player"))
    }

    @Test("a speed picked from the Playback menu reaches the player now and the next play")
    func playbackRateReachesThePlayer() {
        let model = makeModel()
        let player = AVPlayer()
        model.player = player

        model.applyPlaybackRate(1.5)

        #expect(player.defaultRate == 1.5)
    }

    @Test("installPlayer creates a player and resets per-install state")
    func installPlayerCreatesPlayer() {
        let model = makeModel()
        model.currentSegmentID = 99
        model.currentWordID = "stale"
        model.currentTimeSeconds = 42
        model.isPlaying = true

        model.installPlayer(for: Self.makeURL())

        #expect(model.player != nil)
        #expect(model.currentSegmentID == nil)
        #expect(model.currentWordID == nil)
        #expect(model.currentTimeSeconds == 0)
        #expect(model.isPlaying == false)
        #expect(model.hasVideo == false)
    }

    @Test("installPlayer bumps the install token so stale work is ignored")
    func installPlayerBumpsToken() {
        let model = makeModel()
        let before = model.playerInstallToken

        model.installPlayer(for: Self.makeURL())

        #expect(model.playerInstallToken == before &+ 1)
    }

    @Test("the media's length is applied to a transcript that arrives after the player")
    func mediaDurationAppliedToLateTranscript() {
        let model = makeModel()
        model.mediaDurationSeconds = 6164
        model.transcript = Self.makeTranscript([(0, 0, 1)])
        model.adoptLoadedMediaDuration()
        #expect(model.transcript?.durationSeconds == 6164)
    }

    @Test("the media's length replaces a longer recorded duration")
    func mediaDurationCorrectsAnOverlongTranscript() {
        let model = makeModel()
        model.mediaDurationSeconds = 100
        var transcript = Self.makeTranscript([(0, 0, 1)])
        transcript.durationSeconds = 200
        model.transcript = transcript
        model.adoptLoadedMediaDuration()
        #expect(model.transcript?.durationSeconds == 100)
    }

    @Test("a transcript from another entry never takes the loaded media's length")
    func mediaDurationStaysOffForeignTranscript() {
        let model = makeModel()
        model.mediaDurationSeconds = 100
        var transcript = Self.makeTranscript([(0, 0, 1)])
        transcript.durationSeconds = 12
        model.transcript = transcript
        model.applyLoadedMediaDuration()
        #expect(model.transcript?.durationSeconds == 12)
    }

    @Test("tearDownPlayer clears player and all derived state")
    func tearDownClearsState() {
        let model = makeModel()
        model.installPlayer(for: Self.makeURL())
        model.currentSegmentID = 1
        model.currentWordID = "w"
        model.currentTimeSeconds = 5
        model.isPlaying = true
        model.hasVideo = true

        model.tearDownPlayer()

        #expect(model.player == nil)
        #expect(model.currentSegmentID == nil)
        #expect(model.currentWordID == nil)
        #expect(model.currentTimeSeconds == 0)
        #expect(model.isPlaying == false)
        #expect(model.hasVideo == false)
    }

    @Test("tearDownPlayer is a no-op when no player is installed")
    func tearDownNoOp() {
        let model = makeModel()

        model.tearDownPlayer()

        #expect(model.player == nil)
        #expect(model.currentSegmentID == nil)
    }

    @Test("installPlayer twice tears down the first player")
    func reinstallPlayer() throws {
        let model = makeModel()
        model.installPlayer(for: Self.makeURL())
        let first = try #require(model.player)

        model.installPlayer(for: Self.makeURL())

        #expect(model.player !== first)
        #expect(model.player != nil)
    }

    @Test("seek without a player is a no-op")
    func seekSegmentWithoutPlayer() {
        let model = makeModel()
        let segment = TranscriptSegment(id: 1, start: 1, end: 2, text: "x")

        model.seek(to: segment)

        #expect(model.player == nil)
    }

    @Test("seekTo(seconds:) without a player is a no-op")
    func seekSecondsWithoutPlayer() {
        let model = makeModel()

        model.seekTo(seconds: 30)

        #expect(model.player == nil)
    }

    @Test("seekTo(chapter:) without a player is a no-op")
    func seekChapterWithoutPlayer() {
        let model = makeModel()
        let chapter = Chapter(title: "Intro", start: 12)

        model.seekTo(chapter: chapter)

        #expect(model.player == nil)
    }

    @Test("maybeSkipSilence does nothing when skipSilences is off")
    func skipSilenceDisabledByPreference() {
        let model = makeModel()
        model.skipSilences = false
        model.transcript = Self.makeTranscript([(0, 0, 1), (1, 5, 6)])
        model.installPlayer(for: Self.makeURL())
        let startTime = model.currentTimeSeconds

        model.maybeSkipSilence(currentTime: 0.5)

        #expect(model.currentTimeSeconds == startTime)
    }

    @Test("maybeSkipSilence bails out without a transcript")
    func skipSilenceNoTranscript() {
        let model = makeModel()
        model.skipSilences = true
        model.transcript = nil
        model.installPlayer(for: Self.makeURL())

        model.maybeSkipSilence(currentTime: 0)

        #expect(model.player != nil)
    }

    @Test("maybeSkipSilence bails out without a player")
    func skipSilenceNoPlayer() {
        let model = makeModel()
        model.skipSilences = true
        model.transcript = Self.makeTranscript([(0, 0, 1), (1, 5, 6)])

        model.maybeSkipSilence(currentTime: 0.5)

        #expect(model.player == nil)
    }

    @Test("Skip silences never seeks while a segment covers the playhead, even just before its end")
    func silenceSkipInsideSpeech() {
        let segments = Self.makeSegments([(0, 39, 42), (1, 46, 50)])

        #expect(AppModel.silenceSkipTarget(at: 39.5, in: segments, duration: 60) == nil)
        #expect(AppModel.silenceSkipTarget(at: 41.95, in: segments, duration: 60) == nil)
        #expect(AppModel.silenceSkipTarget(at: 42, in: segments, duration: 60) == nil)
        #expect(AppModel.silenceSkipTarget(at: 49.9, in: segments, duration: 60) == nil)
    }

    @Test("Skip silences jumps from a long gap to just before the next segment")
    func silenceSkipLongGap() {
        let segments = Self.makeSegments([(0, 39, 42), (1, 46, 50), (2, 50, 54)])

        #expect(AppModel.silenceSkipTarget(at: 42.1, in: segments, duration: 54) == 46 - 0.1)
        #expect(AppModel.silenceSkipTarget(at: 44, in: segments, duration: 54) == 46 - 0.1)
    }

    @Test("Skip silences leaves back-to-back segments and short gaps alone")
    func silenceSkipBackToBackAndShortGaps() {
        let segments = Self.makeSegments([(0, 10, 12), (1, 12, 15), (2, 15.2, 18), (3, 18.4, 20)])

        #expect(AppModel.silenceSkipTarget(at: 12, in: segments, duration: 20) == nil)
        #expect(AppModel.silenceSkipTarget(at: 15.1, in: segments, duration: 20) == nil)
        #expect(AppModel.silenceSkipTarget(at: 18.2, in: segments, duration: 20) == nil)
    }

    @Test("Skip silences treats speech from an earlier, longer segment as covering the playhead")
    func silenceSkipOverlappingSegments() {
        let segments = Self.makeSegments([(0, 10, 20), (1, 12, 14), (2, 25, 30)])

        #expect(AppModel.silenceSkipTarget(at: 16, in: segments, duration: 30) == nil)
        #expect(AppModel.silenceSkipTarget(at: 21, in: segments, duration: 30) == 25 - 0.1)
    }

    @Test("Skip silences skips a long lead-in before the first segment")
    func silenceSkipLeadIn() {
        let late = Self.makeSegments([(0, 5, 8)])
        let early = Self.makeSegments([(0, 0.3, 8)])

        #expect(AppModel.silenceSkipTarget(at: 0, in: late, duration: 8) == 5 - 0.1)
        #expect(AppModel.silenceSkipTarget(at: 0.1, in: early, duration: 8) == nil)
    }

    @Test("Skip silences jumps from a long silent tail to the end")
    func silenceSkipTail() {
        let segments = Self.makeSegments([(0, 5, 8)])

        #expect(AppModel.silenceSkipTarget(at: 8.2, in: segments, duration: 20) == 20)
        #expect(AppModel.silenceSkipTarget(at: 12, in: segments, duration: 20) == 20)
        #expect(AppModel.silenceSkipTarget(at: 7.9, in: segments, duration: 20) == nil)
    }

    @Test("Skip silences plays a short tail, an unknown length and an empty transcript as they are")
    func silenceSkipTailLeftAlone() {
        let segments = Self.makeSegments([(0, 5, 8)])

        #expect(AppModel.silenceSkipTarget(at: 8.1, in: segments, duration: 8.3) == nil)
        #expect(AppModel.silenceSkipTarget(at: 9, in: segments, duration: 0) == nil)
        #expect(AppModel.silenceSkipTarget(at: 3, in: [], duration: 20) == nil)
    }

    @Test("Skip silences doesn't seek again once the playhead reached its target")
    func silenceSkipAlreadyAtTarget() {
        let segments = Self.makeSegments([(0, 0, 2), (1, 6, 8)])

        #expect(AppModel.silenceSkipTarget(at: 6 - 0.1, in: segments, duration: 12) == nil)
        #expect(AppModel.silenceSkipTarget(at: 5.88, in: segments, duration: 12) == nil)
        #expect(AppModel.silenceSkipTarget(at: 12, in: segments, duration: 12) == nil)
        #expect(AppModel.silenceSkipTarget(at: 13, in: segments, duration: 12) == nil)
    }

    @Test("handleAppResignedActive does nothing when pause-on-hide is off")
    func handleResignedDisabled() {
        let model = makeModel()
        model.pausePlayerOnAppHidden = false
        model.installPlayer(for: Self.makeURL())

        model.handleAppResignedActive()

        #expect(model.player != nil)
    }

    @Test("handleAppResignedActive does nothing when there is no player")
    func handleResignedNoPlayer() {
        let model = makeModel()
        model.pausePlayerOnAppHidden = true

        model.handleAppResignedActive()

        #expect(model.player == nil)
    }

    // MARK: - updateCurrentSegment (karaoke time → highlighted segment/word)

    private static func wordedSegment(
        id: Int, start: Double, end: Double, words: [(id: String, start: Double, end: Double)]
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id, start: start, end: end, text: "seg-\(id)",
            words: words.map { WordTiming(id: $0.id, word: $0.id, start: $0.start, end: $0.end, probability: 1) }
        )
    }

    @Test("updateCurrentSegment resolves the segment covering the time")
    func updateCurrentSegmentResolvesCoveringSegment() {
        let model = makeModel()
        model.transcript = Self.makeTranscript([(0, 0, 2), (1, 3, 5)])

        model.updateCurrentSegment(time: 1)
        #expect(model.currentSegmentID == 0)

        model.updateCurrentSegment(time: 4)
        #expect(model.currentSegmentID == 1)
    }

    @Test("updateCurrentSegment clears the highlight in a gap or outside the range")
    func updateCurrentSegmentClearsOffSegment() {
        let model = makeModel()
        model.transcript = Self.makeTranscript([(0, 0, 2), (1, 3, 5)])

        model.updateCurrentSegment(time: 1)
        #expect(model.currentSegmentID == 0)
        model.updateCurrentSegment(time: 2.5)
        #expect(model.currentSegmentID == nil)

        model.updateCurrentSegment(time: 1)
        model.updateCurrentSegment(time: -0.5)
        #expect(model.currentSegmentID == nil)

        model.updateCurrentSegment(time: 1)
        model.updateCurrentSegment(time: 9)
        #expect(model.currentSegmentID == nil)
    }

    @Test("updateCurrentSegment keeps the cached segment while it still covers the time")
    func updateCurrentSegmentCacheKeepsCoveringSegment() {
        let model = makeModel()
        model.transcript = Self.makeTranscript([(0, 0, 4), (1, 2, 6)])

        model.currentSegmentID = nil
        model.updateCurrentSegment(time: 3)
        #expect(model.currentSegmentID == 0)

        model.currentSegmentID = 1
        model.updateCurrentSegment(time: 3)
        #expect(model.currentSegmentID == 1)
    }

    @Test("updateCurrentSegment re-resolves once the cached segment no longer covers the time")
    func updateCurrentSegmentReResolvesWhenCacheStops() {
        let model = makeModel()
        model.transcript = Self.makeTranscript([(0, 0, 4), (1, 2, 6)])
        model.currentSegmentID = 0

        model.updateCurrentSegment(time: 5)
        #expect(model.currentSegmentID == 1)
    }

    @Test("updateCurrentSegment recovers from a stale cached id that no longer exists")
    func updateCurrentSegmentRecoversFromStaleCache() {
        let model = makeModel()
        model.transcript = Self.makeTranscript([(0, 0, 2), (1, 3, 5)])
        model.currentSegmentID = 99

        model.updateCurrentSegment(time: 1)
        #expect(model.currentSegmentID == 0)
    }

    @Test("updateCurrentSegment tracks the spoken word inside a segment")
    func updateCurrentSegmentTracksWord() {
        let model = makeModel()
        let seg = Self.wordedSegment(id: 0, start: 0, end: 4, words: [
            (id: "0-0", start: 0, end: 1),
            (id: "0-1", start: 1, end: 2)
        ])
        model.transcript = Transcript(segments: [seg], language: "en", modelName: "stub")

        model.updateCurrentSegment(time: 1.5)
        #expect(model.currentSegmentID == 0)
        #expect(model.currentWordID == "0-1")

        model.updateCurrentSegment(time: 3)
        #expect(model.currentSegmentID == 0)
        #expect(model.currentWordID == nil)
    }

    @Test("updateCurrentSegment clears the word when the highlight leaves all segments")
    func updateCurrentSegmentClearsWordOffSegment() {
        let model = makeModel()
        let seg = Self.wordedSegment(id: 0, start: 0, end: 2, words: [(id: "0-0", start: 0, end: 1)])
        model.transcript = Transcript(segments: [seg], language: "en", modelName: "stub")

        model.updateCurrentSegment(time: 0.5)
        #expect(model.currentWordID == "0-0")

        model.updateCurrentSegment(time: 5)
        #expect(model.currentSegmentID == nil)
        #expect(model.currentWordID == nil)
    }

    @Test("updateCurrentSegment is a safe no-op without a transcript")
    func updateCurrentSegmentNoTranscript() {
        let model = makeModel()
        model.transcript = nil
        model.currentSegmentID = 7

        model.updateCurrentSegment(time: 1)
        #expect(model.currentSegmentID == 7)
    }

    // MARK: - skipTarget, skip, togglePlayPause, seekToSegment

    @Test("skipTarget clamps to zero")
    func testSkipTargetClampsToZero() {
        #expect(AppModel.skipTarget(current: 2, by: -5) == 0)
    }

    @Test("skipTarget adds delta")
    func testSkipTargetAddsDelta() {
        #expect(AppModel.skipTarget(current: 10, by: 5) == 15)
        #expect(AppModel.skipTarget(current: 10, by: -5) == 5)
    }

    @Test("Play counts as at the end once the time label reads the total")
    func playbackAtEndFollowsTheLabel() {
        #expect(AppModel.playbackIsAtEnd(current: 159.5, duration: 160))
        #expect(AppModel.playbackIsAtEnd(current: 159.7, duration: 160))
        #expect(AppModel.playbackIsAtEnd(current: 160, duration: 160))
        #expect(AppModel.playbackIsAtEnd(current: 175, duration: 160))
        #expect(!AppModel.playbackIsAtEnd(current: 159.4, duration: 160))
        #expect(!AppModel.playbackIsAtEnd(current: 0, duration: 160))
    }

    @Test("Play counts as at the end within 0.05 s of a length the label hasn't rounded up to")
    func playbackAtEndNearTheRealEnd() {
        #expect(AppModel.playbackIsAtEnd(current: 159.48, duration: 159.52))
        #expect(!AppModel.playbackIsAtEnd(current: 159.3, duration: 159.52))
    }

    @Test("without a known length Play never counts as at the end")
    func playbackAtEndNeedsALength() {
        #expect(!AppModel.playbackIsAtEnd(current: 12, duration: 0))
    }

    @Test("togglePlayPause from the end seeks back to the start, and from mid-way stays put")
    func togglePlayPauseRestartsAtTheEnd() {
        let model = makeModel()
        var transcript = Self.makeTranscript([(0, 0, 150)])
        transcript.durationSeconds = 160
        model.transcript = transcript
        model.installPlayer(for: Self.makeURL())

        model.currentTimeSeconds = 80
        model.togglePlayPause()
        #expect(model.currentTimeSeconds == 80)
        model.player?.pause()

        model.currentTimeSeconds = 159.7
        model.togglePlayPause()
        #expect(model.currentTimeSeconds == 0)
        model.player?.pause()
    }

    @Test("seekToSegment without a player is a no-op")
    func testSeekToSegmentWithoutPlayer() {
        let model = makeModel()
        model.transcript = Self.makeTranscript([(7, 3, 5)])

        model.seekToSegment(id: 7)
        #expect(model.currentSegmentID == nil)
    }

    @Test("adopting the media's length bumps transcriptVersion once")
    func durationAdoptionSingleVersionBump() {
        let model = makeModel()
        model.mediaDurationSeconds = 100
        model.transcript = Self.makeTranscript([(0, 0, 2)])
        let before = model.transcriptVersion
        model.adoptLoadedMediaDuration()
        #expect(model.transcript?.durationSeconds == 100)
        #expect(model.transcriptVersion == before + 1)
    }

    @Test("playback tick caches the segment index and stays correct across segments")
    func segmentIndexCacheTracksPlayback() {
        let model = makeModel()
        model.transcript = Self.makeTranscript([(10, 0, 1), (11, 1.5, 3), (12, 3.5, 5)])

        model.updateCurrentSegment(time: 2.0)
        #expect(model.currentSegmentID == 11)
        #expect(model.currentSegmentIndex == 1)

        model.updateCurrentSegment(time: 2.5)
        #expect(model.currentSegmentID == 11)
        #expect(model.currentSegmentIndex == 1)

        model.updateCurrentSegment(time: 4.0)
        #expect(model.currentSegmentID == 12)
        #expect(model.currentSegmentIndex == 2)

        model.updateCurrentSegment(time: 1.2)
        #expect(model.currentSegmentID == nil)
        #expect(model.currentSegmentIndex == nil)
    }

    @Test("transcript replacement invalidates the cached segment index")
    func segmentIndexCacheInvalidatesOnTranscriptChange() {
        let model = makeModel()
        model.transcript = Self.makeTranscript([(10, 0, 1), (11, 1.5, 3)])
        model.updateCurrentSegment(time: 2.0)
        #expect(model.currentSegmentIndex == 1)

        model.transcript = Self.makeTranscript([(11, 0, 4)])
        #expect(model.currentSegmentIndex == nil)

        model.updateCurrentSegment(time: 2.0)
        #expect(model.currentSegmentID == 11)
        #expect(model.currentSegmentIndex == 0)
    }
}
