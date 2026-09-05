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

        #expect(vote == "it")
    }

    @Test("two noise windows disagreeing lose to the pair that agrees")
    func speechOutvotesNoise() {
        let vote = WhisperLanguageVote.decide([
            reading("cs", 0.7), reading("en", 0.6), reading("it", 0.9), reading("it", 0.85),
        ])

        #expect(vote == "it")
    }

    @Test("an even split leaves the language unpinned")
    func evenSplitDoesNotPin() {
        #expect(WhisperLanguageVote.decide([reading("it", 0.8), reading("cs", 0.8)]) == nil)
    }

    @Test("a reading the detector barely believes is not evidence")
    func lowConfidenceIgnored() {
        let vote = WhisperLanguageVote.decide([reading("cs", 0.05), reading("it", 0.9)])

        #expect(vote == "it")
    }

    @Test("nothing but low-confidence readings leaves the language unpinned")
    func onlyLowConfidence() {
        #expect(WhisperLanguageVote.decide([reading("cs", 0.05), reading("ru", 0.04)]) == nil)
    }

    @Test("no readings leaves the language unpinned")
    func noReadings() {
        #expect(WhisperLanguageVote.decide([]) == nil)
    }

    @Test("one confident reading is enough when there is nothing else to read")
    func singleReading() {
        #expect(WhisperLanguageVote.decide([reading("it", 0.9)]) == "it")
    }

    @Test("a blank language code is not a vote")
    func blankCode() {
        #expect(WhisperLanguageVote.decide([reading("  ", 0.95)]) == nil)
    }
}

@Suite("Whisper language pinning")
struct WhisperLanguagePinTests {
    @Test("an explicit language wins and disables detection")
    func explicitLanguage() {
        let pin = WhisperLanguagePin.resolve(requested: "it", probed: "el")

        #expect(pin.language == "it")
        #expect(pin.detectLanguage == false)
    }

    @Test("a probed language pins the rest of the file")
    func probedLanguage() {
        let pin = WhisperLanguagePin.resolve(requested: nil, probed: "it")

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
        let pin = WhisperLanguagePin.resolve(requested: nil, probed: "  ")

        #expect(pin.language == nil)
        #expect(pin.detectLanguage)
    }
}
