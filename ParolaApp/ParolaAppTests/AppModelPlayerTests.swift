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
