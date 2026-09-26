import Foundation
import Testing
@testable import ParolaCore

@Suite("Parakeet run hints")
struct ParakeetRunHintsTests {
    @Test("a pinned language FluidAudio knows becomes its script hint, whatever the case")
    func pinnedLanguageBecomesTheHint() {
        #expect(ParakeetTranscriber.scriptHint(for: "it")?.rawValue == "it")
        #expect(ParakeetTranscriber.scriptHint(for: "IT")?.rawValue == "it")
        #expect(ParakeetTranscriber.scriptHint(for: "pl")?.rawValue == "pl")
        #expect(ParakeetTranscriber.scriptHint(for: "uk")?.rawValue == "uk")
    }

    @Test("auto language and languages FluidAudio doesn't list run without a hint")
    func noHintOutsideTheList() {
        #expect(ParakeetTranscriber.scriptHint(for: nil) == nil)
        #expect(ParakeetTranscriber.scriptHint(for: "da") == nil)
        #expect(ParakeetTranscriber.scriptHint(for: "ja") == nil)
    }

    @Test("only a file past FluidAudio's progress threshold, plus a second, gets a progress subscriber")
    func progressOnlyPastTheStreamingThreshold() {
        #expect(!ParakeetTranscriber.reportsProgress(forSeconds: 12))
        #expect(!ParakeetTranscriber.reportsProgress(forSeconds: 15))
        #expect(!ParakeetTranscriber.reportsProgress(forSeconds: 16))
        #expect(ParakeetTranscriber.reportsProgress(forSeconds: 17))
        #expect(ParakeetTranscriber.reportsProgress(forSeconds: 25))
        #expect(ParakeetTranscriber.reportsProgress(forSeconds: 3600))
    }

    @Test("a chunk fraction becomes seconds into the file")
    func fractionBecomesSeconds() {
        #expect(ParakeetTranscriber.progressSeconds(fraction: 0.5, duration: 120) == 60)
        #expect(ParakeetTranscriber.progressSeconds(fraction: 1.2, duration: 120) == 120)
        #expect(ParakeetTranscriber.progressSeconds(fraction: -0.1, duration: 120) == 0)
    }
}
