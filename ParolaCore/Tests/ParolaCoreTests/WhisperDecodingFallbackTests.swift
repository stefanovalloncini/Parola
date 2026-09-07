import Foundation
import Testing
import WhisperKit
@testable import ParolaCore

/// The run leans on WhisperKit's own silence fallbacks rather than restating them, so a version
/// bump that quietly drops one would otherwise show up only as hallucinated text on real audio.
@Suite("Whisper decoding fallbacks")
struct WhisperDecodingFallbackTests {
    @Test("the decode defaults still carry Whisper's silence thresholds")
    func silenceThresholdsAreOn() {
        let defaults = DecodingOptions()
        #expect(defaults.noSpeechThreshold == 0.6)
        #expect(defaults.compressionRatioThreshold == 2.4)
        #expect(defaults.logProbThreshold == -1.0)
        #expect(defaults.temperatureFallbackCount == 5)
    }
}
