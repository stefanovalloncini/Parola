import Foundation
import Testing
@testable import ParolaSpeech

@Suite("SpeechLevel")
struct SpeechLevelTests {
    private let rate = 48_000.0

    @Test("silence before speech doesn't count toward its length or level")
    func gatesSilence() throws {
        let speech = (0..<4_800).map { Float(0.1 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let measure = SpeechMeasure(Array(repeating: 0, count: 4_800) + speech, sampleRate: rate)
        #expect(abs(measure.seconds - 0.1) < 0.011)
        let levelDB = try #require(measure.levelDB)
        #expect(abs(levelDB - 20 * log10(0.1 / sqrt(2))) < 0.2)
    }

    @Test("silence alone measures nothing and leaves the level where it was")
    func silenceMeasuresNothing() {
        let measure = SpeechMeasure(Array(repeating: 0, count: 48_000), sampleRate: rate)
        var level = SpeechLevel()
        level.absorb(measure)
        #expect(measure.seconds == 0)
        #expect(measure.levelDB == nil)
        #expect(level == SpeechLevel())
    }

    @Test("quiet speech never raises the gain above unity")
    func neverBoosts() {
        var level = SpeechLevel()
        let quiet = SpeechMeasure(Array(repeating: 0.005, count: 48_000), sampleRate: rate)
        for _ in 0..<30 { level.absorb(quiet) }
        #expect(level.gainDB == 0)
        #expect(level.gain == 1)
    }

    @Test("very loud speech is held at -12 dB")
    func cutIsBounded() {
        var level = SpeechLevel()
        let loud = SpeechMeasure(Array(repeating: 0.9, count: 48_000), sampleRate: rate)
        for _ in 0..<30 { level.absorb(loud) }
        #expect(level.gainDB == -12)
    }
}
