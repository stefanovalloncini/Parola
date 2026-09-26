import Foundation
import Testing
@testable import ParolaCore

@Suite("Live line tidier")
struct LiveLineTidierTests {
    private func line(_ text: String) -> TranscriptSegment {
        TranscriptSegment(id: 0, start: 0, end: 1, text: text)
    }

    @Test("a pinned Italian take gets the orthography fix on every line")
    func pinnedLanguageFixesEachLine() {
        var tidier = LiveLineTidier(language: "it")
        #expect(tidier.tidy(line(" perchè no")).map(\.text) == "perché no")
        #expect(tidier.tidy(line("un pò")).map(\.text) == "un po'")
    }

    @Test("a stock credit line never prints")
    func hallucinationLineIsDropped() {
        var tidier = LiveLineTidier(language: "it")
        #expect(tidier.tidy(line("Sottotitoli creati dalla comunità Amara.org")) == nil)
        #expect(tidier.tidy(line("   ")) == nil)
    }

    @Test("an English take is left as spoken")
    func otherLanguagesAreUntouched() {
        var tidier = LiveLineTidier(language: nil)
        _ = tidier.tidy(line("Good morning everyone, today we are going through the quarterly budget review."))
        #expect(tidier.tidy(line("The café said perchè on the sign.")).map(\.text) == "The café said perchè on the sign.")
    }

    @Test("user rules run on live lines when a surface passes them")
    func userRulesApply() {
        var tidier = LiveLineTidier(
            language: "it",
            postProcessor: TranscriptPostProcessor(findReplaceRules: [FindReplaceRule(find: "perchè", replace: "per quale motivo")])
        )
        #expect(tidier.tidy(line("perchè no")).map(\.text) == "per quale motivo no")
    }
}
