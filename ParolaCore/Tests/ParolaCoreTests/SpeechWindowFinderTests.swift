import Foundation
import Testing
@testable import ParolaCore

@Suite("Speech window finder")
struct SpeechWindowFinderTests {
    private let sampleRate = 16_000

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    private func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate)))
        }
    }

    @Test("skips leading silence and lands on the first sustained speech")
    func skipsLeadingSilence() throws {
        let samples = silence(seconds: 12) + tone(seconds: 5)

        let offset = SpeechWindowFinder.firstSpeechOffset(in: samples, sampleRate: sampleRate)

        let seconds = Double(try #require(offset)) / Double(sampleRate)
        #expect(seconds >= 11.5 && seconds <= 12.5)
    }

    @Test("returns zero when speech starts immediately")
    func speechFromTheStart() {
        let offset = SpeechWindowFinder.firstSpeechOffset(
            in: tone(seconds: 4), sampleRate: sampleRate
        )

        #expect(offset == 0)
    }

    @Test("a silent file has no speech window")
    func allSilence() {
        #expect(SpeechWindowFinder.firstSpeechOffset(in: silence(seconds: 30), sampleRate: sampleRate) == nil)
    }

    @Test("an isolated click is too short to count as speech")
    func ignoresShortBursts() {
        let samples = silence(seconds: 3) + tone(seconds: 0.2) + silence(seconds: 3)

        #expect(SpeechWindowFinder.firstSpeechOffset(in: samples, sampleRate: sampleRate) == nil)
    }

    @Test("a click before real speech does not win over the sustained stretch")
    func prefersSustainedSpeechOverClick() throws {
        let samples = silence(seconds: 2) + tone(seconds: 0.2) + silence(seconds: 8) + tone(seconds: 6)

        let offset = SpeechWindowFinder.firstSpeechOffset(in: samples, sampleRate: sampleRate)

        let seconds = Double(try #require(offset)) / Double(sampleRate)
        #expect(seconds >= 9.5 && seconds <= 10.5)
    }

    @Test("an empty waveform has no speech window")
    func emptyWaveform() {
        #expect(SpeechWindowFinder.firstSpeechOffset(in: [], sampleRate: sampleRate) == nil)
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
