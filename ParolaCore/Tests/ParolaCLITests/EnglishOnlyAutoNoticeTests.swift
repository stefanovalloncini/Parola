import Foundation
import Testing
import ParolaCore
@testable import parola

@Suite("English-only auto-language CLI notice")
struct EnglishOnlyAutoNoticeTests {
    @Test("an English-only model gets the exact notice text")
    func englishOnlyModelGetsNotice() {
        let text = englishOnlyAutoNoticeText(model: "nvidia_parakeet-tdt-0.6b-v2")
        #expect(text == "Parakeet TDT 0.6B v2 only transcribes English; transcribing as English. Pass -l to pick a multilingual model.")
    }

    @Test("a multilingual model gets no notice")
    func multilingualModelGetsNoNotice() {
        #expect(englishOnlyAutoNoticeText(model: "openai_whisper-large-v3_turbo") == nil)
        #expect(englishOnlyAutoNoticeText(model: "apple-speech-analyzer") == nil)
    }

    @Test("an unknown model gets no notice")
    func unknownModelGetsNoNotice() {
        #expect(englishOnlyAutoNoticeText(model: "not-a-real-model") == nil)
    }
}

@Suite("Saved bundle provenance")
struct TranscribeEntrySourceTests {
    @Test("a link saves as a link and a file saves as a file")
    func entrySourceFollowsTheInput() throws {
        let link = try #require(URL(string: "https://www.youtube.com/watch?v=abc"))
        #expect(Transcribe.ResolvedInput.youtube(link).entrySource == .web)
        #expect(Transcribe.ResolvedInput.file(URL(fileURLWithPath: "/tmp/talk.wav")).entrySource == .file)
    }
}
