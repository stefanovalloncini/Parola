import Foundation
import Testing
@testable import ParolaCore

@Suite("Speech window finder")
struct SpeechWindowFinderTests {
    private let sampleRate = 16_000
    private var windowLength: Int { 30 * sampleRate }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    private func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate)))
        }
    }

    @Test("the loudest stretch is offered first")
    func loudestFirst() throws {
        let samples = silence(seconds: 30) + tone(seconds: 30) + silence(seconds: 30)

        let offsets = SpeechWindowFinder.loudestWindowOffsets(
            in: samples, windowLength: windowLength, limit: 3
        )

        let seconds = Double(try #require(offsets.first)) / Double(sampleRate)
        #expect(seconds >= 25 && seconds <= 35)
    }

    @Test("a quiet stretch is still offered once the loud ones are taken")
    func quieterStretchesFollow() {
        let samples = tone(seconds: 30, amplitude: 0.4)
            + tone(seconds: 30, amplitude: 0.05)
            + tone(seconds: 30, amplitude: 0.2)

        let offsets = SpeechWindowFinder.loudestWindowOffsets(
            in: samples, windowLength: windowLength, limit: 3
        )

        #expect(offsets.count == 3)
    }

    @Test("picked windows never overlap")
    func windowsDoNotOverlap() {
        let samples = tone(seconds: 120)

        let offsets = SpeechWindowFinder.loudestWindowOffsets(
            in: samples, windowLength: windowLength, limit: 4
        )

        let sorted = offsets.sorted()
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            #expect(later - earlier >= windowLength)
        }
    }

    @Test("limit caps how many windows are offered")
    func limitCaps() {
        let offsets = SpeechWindowFinder.loudestWindowOffsets(
            in: tone(seconds: 300), windowLength: windowLength, limit: 2
        )

        #expect(offsets.count == 2)
    }

    @Test("a waveform shorter than one window starts at zero")
    func shorterThanOneWindow() {
        let offsets = SpeechWindowFinder.loudestWindowOffsets(
            in: tone(seconds: 8), windowLength: windowLength, limit: 4
        )

        #expect(offsets == [0])
    }

    @Test("silence still yields windows so the probe has something to read")
    func silenceStillYieldsWindows() {
        let offsets = SpeechWindowFinder.loudestWindowOffsets(
            in: silence(seconds: 120), windowLength: windowLength, limit: 3
        )

        #expect(!offsets.isEmpty)
    }

    @Test("a file ending mid-window still offers its tail")
    func trailingPartialWindow() {
        let offsets = SpeechWindowFinder.loudestWindowOffsets(
            in: tone(seconds: 59.9), windowLength: windowLength, limit: 3, hopLength: windowLength
        )

        #expect(offsets.count == 2)
    }

    @Test("a sliver at the end is not a window")
    func shortTailIsNotAWindow() {
        let offsets = SpeechWindowFinder.loudestWindowOffsets(
            in: tone(seconds: 35), windowLength: windowLength, limit: 3, hopLength: windowLength
        )

        #expect(offsets == [0])
    }

    @Test("an empty waveform has no windows")
    func emptyWaveform() {
        #expect(SpeechWindowFinder.loudestWindowOffsets(in: [], windowLength: windowLength, limit: 3).isEmpty)
    }
}

@Suite("Whisper language vote")
struct WhisperLanguageVoteTests {
    private func reading(_ language: String, _ confidence: Double) -> WhisperLanguageReading {
        WhisperLanguageReading(language: language, confidence: confidence)
    }

    @Test("windows that agree pin the language")
    func agreementPins() {
        let vote = WhisperLanguageVote.decide([reading("it", 0.9), reading("it", 0.8)])

        #expect(vote == .detected("it"))
    }

    @Test("two noise windows disagreeing lose to the pair that agrees")
    func speechOutvotesNoise() {
        let vote = WhisperLanguageVote.decide([
            reading("cs", 0.7), reading("en", 0.6), reading("it", 0.9), reading("it", 0.85),
        ])

        #expect(vote == .detected("it"))
    }

    @Test("an even split leaves the language unpinned")
    func evenSplitDoesNotPin() {
        #expect(WhisperLanguageVote.decide([reading("it", 0.8), reading("cs", 0.8)]) == nil)
    }

    @Test("a reading the detector barely believes is not evidence")
    func lowConfidenceIgnored() {
        let vote = WhisperLanguageVote.decide([reading("cs", 0.05), reading("it", 0.99)])

        #expect(vote == .detected("it"))
    }

    @Test("a dissenting second reading still leaves a clear winner")
    func dissentingSecondReading() {
        let vote = WhisperLanguageVote.decide([reading("cs", 0.11), reading("it", 0.9)])

        #expect(vote == .detected("it"))
    }

    @Test("nothing but low-confidence readings leaves the language unpinned")
    func onlyLowConfidence() {
        #expect(WhisperLanguageVote.decide([reading("cs", 0.05), reading("ru", 0.04)]) == nil)
    }

    @Test("no readings leaves the language unpinned")
    func noReadings() {
        #expect(WhisperLanguageVote.decide([]) == nil)
    }

    @Test("a lone reading counts as detected when it is near-certain")
    func singleCertainReading() {
        #expect(WhisperLanguageVote.decide([reading("it", 0.99)]) == .detected("it"))
    }

    @Test("a lone reading the detector half believes is only an assumption")
    func singleHalfHeartedReading() {
        #expect(WhisperLanguageVote.decide([reading("cs", 0.45)]) == .assumed("cs"))
    }

    @Test("a blank language code is not a vote")
    func blankCode() {
        #expect(WhisperLanguageVote.decide([reading("  ", 0.95)]) == nil)
    }

    @Test("a vote the unread windows could still overturn keeps reading")
    func unreadWindowsKeepTheVoteOpen() {
        let readings = [reading("it", 0.98), reading("it", 0.97)]

        #expect(!WhisperLanguageVote.isSettled(readings, unread: 2))
        #expect(WhisperLanguageVote.isSettled(readings, unread: 1))
        #expect(WhisperLanguageVote.isSettled(readings, unread: 0))
    }

    @Test("one reading never settles while a window is left")
    func oneReadingDoesNotSettle() {
        #expect(!WhisperLanguageVote.isSettled([reading("it", 0.9999)], unread: 1))
        #expect(!WhisperLanguageVote.isSettled([], unread: 0))
    }

    @Test("agreement without the lead is not settled")
    func agreementWithoutLeadDoesNotSettle() {
        let readings = [reading("it", 0.9), reading("it", 0.9), reading("en", 0.99), reading("en", 0.99)]

        #expect(!WhisperLanguageVote.isSettled(readings, unread: 0))
        #expect(WhisperLanguageVote.decide(readings) == nil)
    }

    @Test("a lead the unread window could still erase keeps reading")
    func thinLeadKeepsReading() async {
        let readings = [reading("it", 0.99), reading("it", 0.99), reading("en", 0.9)]
        let probe = await read(readings + [reading("en", 1.0)])

        #expect(!WhisperLanguageVote.isSettled(readings, unread: 1))
        #expect(probe.asked == [0, 1, 2, 3])
        #expect(WhisperLanguageVote.decide(probe.readings) == nil)
    }

    @Test("a settled vote stops reading")
    func settledVoteStopsReading() async {
        let probe = await read(Array(repeating: reading("it", 0.98), count: 4))

        #expect(probe.asked == [0, 1, 2])
        #expect(WhisperLanguageVote.decide(probe.readings) == .detected("it"))
    }

    @Test("the 159 memo settles on its third window")
    func memoSettlesOnTheThirdWindow() async {
        let probe = await read([reading("it", 0.981), reading("en", 0.554), reading("it", 0.995), reading("it", 0.993)])

        #expect(probe.asked == [0, 1, 2])
        #expect(WhisperLanguageVote.decide(probe.readings) == .detected("it"))
    }

    @Test("a bilingual memo is read to the end and left to per-chunk detection")
    func bilingualMemoIsNeverPinned() async {
        let probe = await read([reading("it", 0.97), reading("it", 0.96), reading("en", 0.95), reading("en", 0.90)])

        #expect(probe.asked == [0, 1, 2, 3])
        #expect(WhisperLanguageVote.decide(probe.readings) == nil)
    }

    @Test("two confident noise windows ahead of the speech never pin their language")
    func noiseAheadOfSpeechIsNeverPinned() async {
        let probe = await read([reading("cs", 0.90), reading("cs", 0.88), reading("it", 0.99), reading("it", 0.99)])

        #expect(probe.asked == [0, 1, 2, 3])
        #expect(WhisperLanguageVote.decide(probe.readings) == nil)
    }

    @Test("a window that fails to read still counts as read")
    func failedReadsAreSkipped() async {
        let probe = await read([nil, reading("it", 0.7), nil])

        #expect(probe.asked == [0, 1, 2])
        #expect(WhisperLanguageVote.decide(probe.readings) == .assumed("it"))
    }

    @Test("stopping early never changes the vote")
    func earlyStopMatchesTheFullVote() async {
        let languages = ["it", "en", "cs"]
        let confidences = [0.05, 0.3, 0.5, 0.56, 0.75, 0.85, 0.9, 0.97, 0.99, 1.0]
        var seed: UInt64 = 0x2C77_EE98
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        var stoppedEarly = 0
        for _ in 0..<3_000 {
            let script: [WhisperLanguageReading?] = (0..<(1 + next(5))).map { _ in
                next(10) == 0 ? nil : reading(languages[next(languages.count)], confidences[next(confidences.count)])
            }
            let probe = await read(script)
            if probe.asked.count < script.count { stoppedEarly += 1 }
            #expect(WhisperLanguageVote.decide(probe.readings) == WhisperLanguageVote.decide(script.compactMap { $0 }))
        }
        #expect(stoppedEarly > 100)
    }

    private func read(
        _ script: [WhisperLanguageReading?]
    ) async -> (readings: [WhisperLanguageReading], asked: [Int]) {
        var asked: [Int] = []
        let readings = await WhisperLanguageVote.readings(windowCount: script.count) { index in
            asked.append(index)
            return script[index]
        }
        return (readings, asked)
    }
}

@Suite("Whisper language pinning")
struct WhisperLanguagePinTests {
    @Test("an explicit language wins and disables detection")
    func explicitLanguage() {
        let pin = WhisperLanguagePin.resolve(requested: "it", probed: .detected("el"))

        #expect(pin.language == "it")
        #expect(pin.detectLanguage == false)
    }

    @Test("a probed language pins the rest of the file")
    func probedLanguage() {
        let pin = WhisperLanguagePin.resolve(requested: nil, probed: .detected("it"))

        #expect(pin.language == "it")
        #expect(pin.detectLanguage == false)
    }

    @Test("a failed probe falls back to per-chunk detection")
    func failedProbe() {
        let pin = WhisperLanguagePin.resolve(requested: nil, probed: nil)

        #expect(pin.language == nil)
        #expect(pin.detectLanguage)
    }

    @Test("an empty probe result is not treated as a language")
    func emptyProbe() {
        let pin = WhisperLanguagePin.resolve(requested: nil, probed: .assumed("  "))

        #expect(pin.language == nil)
        #expect(pin.detectLanguage)

        let detection = WhisperLanguagePin.detection(
            requested: nil, probed: .assumed("  "), ranAs: "el", canDetect: true
        )
        #expect(detection == .assumed("el"))
    }

    @Test("a corroborated probe is reported as detected")
    func detectedProbeIsReported() {
        let detection = WhisperLanguagePin.detection(
            requested: nil, probed: .detected("it"), ranAs: "it", canDetect: true
        )

        #expect(detection == .detected("it"))
    }

    @Test("a probe that won by default is reported as assumed")
    func assumedProbeIsReported() {
        let detection = WhisperLanguagePin.detection(
            requested: nil, probed: .assumed("cs"), ranAs: "cs", canDetect: true
        )

        #expect(detection == .assumed("cs"))
    }

    @Test("a failed probe leaves the run's own language reported as assumed")
    func failedProbeIsAssumed() {
        let detection = WhisperLanguagePin.detection(
            requested: nil, probed: nil, ranAs: "el", canDetect: true
        )

        #expect(detection == .assumed("el"))
    }

    @Test("a language the caller named is reported as neither")
    func explicitLanguageReportsNothing() {
        let detection = WhisperLanguagePin.detection(
            requested: "it", probed: nil, ranAs: "it", canDetect: true
        )

        #expect(detection == nil)
    }

    @Test("an English-only model reports nothing about the language")
    func monolingualModelReportsNothing() {
        let detection = WhisperLanguagePin.detection(
            requested: nil, probed: nil, ranAs: "en", canDetect: false
        )

        #expect(detection == nil)
    }
}
