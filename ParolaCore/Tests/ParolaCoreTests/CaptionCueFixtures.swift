import Foundation
@testable import ParolaCore

enum CaptionCueFixtures {
    static let longText = "So the thing about building a transcription app is that every part of it looks simple until you try to make it work for a two hour meeting recorded on a laptop in a noisy café, and then the captions have to fit on a phone screen held upright."

    static func timedWords(_ text: String, from start: Double, step: Double = 0.4, silenceAfter: Int? = nil, silence: Double = 2.5) -> [WordTiming] {
        var clock = start
        return text.split(whereSeparator: \.isWhitespace).enumerated().map { index, word in
            defer {
                clock += step
                if index + 1 == silenceAfter { clock += silence }
            }
            return WordTiming(id: "w\(index)", word: String(word), start: clock, end: clock + step - 0.05, probability: 1)
        }
    }

    static func transcript(_ segments: [TranscriptSegment], language: String = "en", translation: [Int: String]? = nil, target: String = "it") -> Transcript {
        Transcript(
            segments: segments, language: language, modelName: "test",
            translation: translation.map { TranscriptTranslation(targetLanguage: target, segments: $0, createdAt: Date(timeIntervalSince1970: 0), provider: "test") }
        )
    }

    struct Case {
        let name: String
        let transcript: Transcript
        var speakers = false
        var grouping = ExportGrouping.none
        var content = ExportContent.original
        var overlaps = false
        var tall = false
    }

    static var cases: [Case] {
        let timed = TranscriptSegment(id: 0, start: 10, end: 10 + 0.4 * 49 + 2.5, text: longText, words: timedWords(longText, from: 10, silenceAfter: 24))
        let untimed = TranscriptSegment(id: 0, start: 10, end: 28, text: longText)
        let paragraph = [
            TranscriptSegment(id: 0, start: 0, end: 6, text: "Thanks for joining everyone, I know the schedule is tight this week.", speaker: "Ada"),
            TranscriptSegment(id: 1, start: 6, end: 8, text: "First item is the export rewrite.", speaker: "Ada"),
            TranscriptSegment(id: 2, start: 14, end: 24, text: "We shipped the new splitter on Monday and the captions finally follow the speech instead of the segment, which means long answers no longer sit on screen for fifteen seconds.", speaker: "Ada"),
            TranscriptSegment(id: 3, start: 25, end: 27, text: "Great, thank you.", speaker: "Grace"),
        ]
        let japanese = "今日は新しい字幕の分割について説明します。長い文章は読みやすい長さに切り、話している間だけ画面に表示されます。"
        let short = [
            TranscriptSegment(id: 0, start: 1, end: 1.3, text: "Yes."),
            TranscriptSegment(id: 1, start: 5, end: 5.2, text: "Okay, so."),
            TranscriptSegment(id: 2, start: 5.6, end: 5.7, text: "Right."),
            TranscriptSegment(id: 3, start: 9, end: 9, text: "Zero length."),
        ]
        let adjacent = [
            TranscriptSegment(id: 0, start: 0, end: 4.5, text: "The first segment runs a little past the start of the second one and says a good deal more than fits."),
            TranscriptSegment(id: 1, start: 4, end: 8, text: "The second begins before the first is done."),
            TranscriptSegment(id: 2, start: 8, end: 12, text: "The third starts exactly where the second ends."),
        ]
        return [
            Case(name: "long-timed", transcript: transcript([timed])),
            Case(name: "long-untimed", transcript: transcript([untimed])),
            Case(name: "merged-paragraph", transcript: transcript(paragraph), speakers: true, grouping: .speakerParagraphs),
            Case(name: "speakers", transcript: transcript(paragraph), speakers: true),
            Case(name: "japanese-original", transcript: transcript([TranscriptSegment(id: 0, start: 0, end: 9, text: japanese)], language: "ja")),
            Case(name: "japanese-translation", transcript: transcript([TranscriptSegment(id: 0, start: 0, end: 9, text: "Today I will explain the new caption splitting. Long sentences are cut to a readable length and shown only while they are spoken.")], translation: [0: japanese], target: "ja"), content: .translation),
            Case(name: "japanese-both", transcript: transcript([TranscriptSegment(id: 0, start: 0, end: 9, text: "Today I will explain the new caption splitting. Long sentences are cut to a readable length and shown only while they are spoken.")], translation: [0: japanese], target: "ja"), content: .both),
            Case(name: "italian-both", transcript: transcript([untimed], translation: [0: "La cosa che riguarda la costruzione di un'app di trascrizione è che ogni parte sembra semplice finché non provi a farla funzionare per una riunione di due ore registrata su un portatile in un caffè rumoroso, e poi i sottotitoli devono stare su uno schermo di telefono tenuto in verticale."]), content: .both),
            Case(name: "very-short", transcript: transcript(short)),
            Case(name: "adjacent", transcript: transcript(adjacent)),
            Case(name: "zero-length-long", transcript: transcript([TranscriptSegment(id: 0, start: 5, end: 5, text: longText)]), tall: true),
            Case(name: "start-after-end", transcript: transcript([TranscriptSegment(id: 0, start: 10, end: 4, text: longText)]), tall: true),
            Case(name: "same-start", transcript: transcript([
                TranscriptSegment(id: 0, start: 0, end: 6, text: "The first speaker keeps talking for a while about something."),
                TranscriptSegment(id: 1, start: 0, end: 6, text: "The second speaker starts at the very same moment."),
            ]), overlaps: true),
            Case(name: "interjection", transcript: transcript([
                TranscriptSegment(id: 0, start: 0, end: 20, text: longText),
                TranscriptSegment(id: 1, start: 8, end: 8.6, text: "Mm-hmm."),
            ]), overlaps: true),
            Case(name: "tiny-before-next", transcript: transcript([
                TranscriptSegment(id: 0, start: 4, end: 4.01, text: "So."),
                TranscriptSegment(id: 1, start: 4.01, end: 9, text: "The thing is that it works now."),
            ]), overlaps: true, tall: true),
            Case(name: "short-original-long-translation", transcript: transcript(
                [TranscriptSegment(id: 0, start: 0, end: 8, text: "Yes, of course.")],
                translation: [0: "Sì, certamente, naturalmente, senza alcun dubbio, e anche volentieri, se me lo chiedi."]
            ), content: .both),
            Case(name: "one-word-translation", transcript: transcript([untimed], translation: [0: "Sì."]), content: .both),
            Case(name: "label-width", transcript: transcript([
                TranscriptSegment(id: 0, start: 0, end: 8, text: "I think we should ship the new captions on Friday morning before the board meeting", speaker: "Ada"),
            ]), speakers: true),
            Case(name: "long-word", transcript: transcript([
                TranscriptSegment(id: 0, start: 0, end: 8, text: "ok https://example.com/a/very/long/path/that/goes/on/and/on/forever/and/ever/index.html"),
            ])),
        ]
    }

    static func spec(_ item: Case, format: ExportFormat, length: CaptionLength) -> ExportSpec {
        var spec = ExportSpec.standard(for: format)
        spec.options.captionLength = length
        spec.options.speakers = item.speakers
        spec.options.grouping = item.grouping
        spec.options.content = item.content
        return spec
    }
}
