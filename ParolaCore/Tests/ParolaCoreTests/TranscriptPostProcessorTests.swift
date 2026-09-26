import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcript post-processor")
struct TranscriptPostProcessorTests {
    private static func transcript(_ texts: [String], language: String = "it") -> Transcript {
        Transcript(
            segments: texts.enumerated().map { TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: $1) },
            language: language,
            modelName: "openai_whisper-tiny"
        )
    }

    @Test("user rules run before the orthography pass, so a rule on the engine's spelling still matches")
    func rulesRunFirst() {
        let processor = TranscriptPostProcessor(
            ignoredRules: [IgnoredSegmentRule(pattern: "ehm")],
            findReplaceRules: [FindReplaceRule(find: "perchè", replace: "per quale motivo")]
        )

        let out = processor.apply(Self.transcript(["ehm", "perchè no", "un pò di più", "finchè dura"]))

        #expect(out.segments.map(\.text) == ["per quale motivo no", "un po' di più", "finché dura"])
    }

    @Test("orthography-only fixes Italian and leaves every other language alone")
    func orthographyOnlyIsLanguageGated() {
        let italian = TranscriptPostProcessor.orthographyOnly.apply(Self.transcript(["perchè un pò"]))
        let english = TranscriptPostProcessor.orthographyOnly.apply(Self.transcript(["perchè un pò"], language: "en"))

        #expect(italian.segments.map(\.text) == ["perché un po'"])
        #expect(english.segments.map(\.text) == ["perchè un pò"])
    }

    @Test("the off-actor pass gives the same result as the synchronous one")
    func offActorMatchesSync() async {
        let processor = TranscriptPostProcessor(findReplaceRules: [FindReplaceRule(find: "teh", replace: "the")])
        let input = Self.transcript(["teh perchè"])

        let detached = await processor.applyOffActor(input)

        #expect(detached == processor.apply(input))
    }
}
