import Foundation
import Testing
@testable import ParolaCore

@Suite("Spoken language real code")
struct SpokenLanguageRealCodeTests {
    @Test("nil, empty and whitespace have no real code")
    func blank() {
        #expect(SpokenLanguage.realCode(nil) == nil)
        #expect(SpokenLanguage.realCode("") == nil)
        #expect(SpokenLanguage.realCode("  ") == nil)
    }

    @Test("the auto and unknown sentinels have no real code, case-insensitively")
    func sentinels() {
        #expect(SpokenLanguage.realCode("auto") == nil)
        #expect(SpokenLanguage.realCode("AUTO") == nil)
        #expect(SpokenLanguage.realCode("unknown") == nil)
    }

    @Test("a real code is trimmed and kept as is")
    func realCode() {
        #expect(SpokenLanguage.realCode("it") == "it")
        #expect(SpokenLanguage.realCode(" it ") == "it")
        #expect(SpokenLanguage.realCode("en-GB") == "en-GB")
    }
}

@Suite("Spoken language for transcript")
struct SpokenLanguageForTranscriptTests {
    private func segment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(id: 0, start: 0, end: 1, text: text)
    }

    @Test("a real language is used as is")
    func realLanguage() {
        let transcript = Transcript(segments: [segment("hello")], language: "it", modelName: "test")
        #expect(SpokenLanguage.forTranscript(transcript, uiLanguage: "en") == "it")
    }

    @Test("auto falls back to a guess over Italian segments")
    func autoGuessesItalian() {
        let transcript = Transcript(
            segments: [segment("Buongiorno a tutti, oggi parliamo della distinta base e dei componenti ordinati.")],
            language: "auto",
            modelName: "test"
        )
        #expect(SpokenLanguage.forTranscript(transcript, uiLanguage: "fr") == "it")
    }

    @Test("unknown falls back to a guess over English segments")
    func unknownGuessesEnglish() {
        let transcript = Transcript(
            segments: [segment("Ask not what your country can do for you, ask what you can do for your country.")],
            language: "unknown",
            modelName: "test"
        )
        #expect(SpokenLanguage.forTranscript(transcript, uiLanguage: "fr") == "en")
    }

    @Test("Parakeet's assumed English is overridden by Italian segments")
    func assumedEnglishIsOverridden() {
        let transcript = Transcript(
            segments: [segment("Buongiorno a tutti, oggi parliamo della distinta base e dei componenti ordinati.")],
            language: "en",
            modelName: "test",
            languageDetection: .assumed("en")
        )
        #expect(SpokenLanguage.forTranscript(transcript, uiLanguage: "fr") == "it")
    }

    @Test("no letters anywhere falls back to the UI language")
    func noLettersFallsBackToUILanguage() {
        let transcript = Transcript(segments: [segment("12 34 56")], language: "auto", modelName: "test")
        #expect(SpokenLanguage.forTranscript(transcript, uiLanguage: "fr") == "fr")
    }
}

@Suite("Spoken language for translation")
struct SpokenLanguageForTranslationTests {
    @Test("returns the target language as is")
    func targetLanguage() {
        #expect(SpokenLanguage.forTranslation(targetLanguage: "it") == "it")
    }
}

@Suite("Spoken language for summary")
struct SpokenLanguageForSummaryTests {
    @Test("an Italian summary wins over the transcript's English")
    func italianSummaryOverEnglishTranscript() {
        let language = SpokenLanguage.forSummary(
            text: "Oggi abbiamo discusso della distinta base e dei componenti ordinati al magazzino.",
            chapterTitles: [],
            actionItems: [],
            transcriptLanguage: "en"
        )
        #expect(language == "it")
    }

    @Test("a digits-only summary falls back to the transcript's language")
    func digitsOnlyFallsBackToTranscriptLanguage() {
        let language = SpokenLanguage.forSummary(
            text: "12 34 56",
            chapterTitles: [],
            actionItems: [],
            transcriptLanguage: "en"
        )
        #expect(language == "en")
    }

    @Test("empty text with Italian chapter titles is guessed from the titles")
    func emptyTextWithItalianChapterTitles() {
        let language = SpokenLanguage.forSummary(
            text: "",
            chapterTitles: ["Riunione sulla distinta base e sui componenti ordinati al magazzino"],
            actionItems: [],
            transcriptLanguage: "en"
        )
        #expect(language == "it")
    }
}

@Suite("Spoken language base code")
struct SpokenLanguageBaseCodeTests {
    @Test("a region or script suffix reduces to its language")
    func reducesToLanguage() {
        #expect(SpokenLanguage.baseCode("en-GB") == "en")
        #expect(SpokenLanguage.baseCode("EN") == "en")
        #expect(SpokenLanguage.baseCode("zh-Hant") == "zh")
        #expect(SpokenLanguage.baseCode("zh-HK") == "zh")
        #expect(SpokenLanguage.baseCode("pt-BR") == "pt")
        #expect(SpokenLanguage.baseCode("it") == "it")
    }

    @Test("Cantonese stays yue")
    func cantoneseStaysYue() {
        #expect(SpokenLanguage.baseCode("yue") == "yue")
    }
}
