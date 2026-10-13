import CoreGraphics
import Foundation
import Testing
@testable import ParolaCore

@Suite("Caption cue files")
struct CaptionCueFileTests {
    private struct ParsedCue {
        let start: Double
        let end: Double
        let lines: [String]
    }

    private func seconds(_ stamp: Substring) -> Double {
        let parts = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        return (Double(parts[0]) ?? 0) * 3600 + (Double(parts[1]) ?? 0) * 60 + (Double(parts[2]) ?? 0)
    }

    private func parse(_ srt: String) -> [ParsedCue] {
        srt.components(separatedBy: "\n\n").compactMap { block in
            let rows = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard rows.count >= 3, let arrow = rows[1].range(of: " --> ") else { return nil }
            return ParsedCue(
                start: seconds(rows[1][..<arrow.lowerBound]), end: seconds(rows[1][arrow.upperBound...]),
                lines: Array(rows[2...]).filter { !$0.isEmpty }
            )
        }
    }

    private func srt(_ item: CaptionCueFixtures.Case, length: CaptionLength) throws -> [ParsedCue] {
        let exporter = SrtExporter(spec: CaptionCueFixtures.spec(item, format: .srt, length: length))
        return parse(try exporter.renderText(item.transcript))
    }

    private func item(_ name: String) throws -> CaptionCueFixtures.Case {
        try #require(CaptionCueFixtures.cases.first { $0.name == name })
    }

    @Test("every case at every length writes ordered, non-overlapping cues of positive length")
    func cuesAreOrderedAndApart() throws {
        for item in CaptionCueFixtures.cases {
            for length in [CaptionLength.short, .medium, .long] {
                let cues = try srt(item, length: length)
                #expect(!cues.isEmpty)
                for cue in cues { #expect(cue.end > cue.start, "\(item.name) \(length)") }
                for (earlier, later) in zip(cues, cues.dropFirst()) where !item.overlaps {
                    #expect(earlier.end <= later.start + 0.0005, "\(item.name) \(length): \(earlier) overlaps \(later)")
                }
            }
        }
    }

    @Test("a cue holds at most two lines, or one of each language, none wider than the limit")
    func cueShape() throws {
        for item in CaptionCueFixtures.cases {
            for length in [CaptionLength.short, .medium, .long] {
                let limit = try #require(length.maxCharsPerLine)
                for cue in try srt(item, length: length) {
                    if !item.tall { #expect(cue.lines.count <= 2, "\(item.name) \(length)") }
                    for line in cue.lines where item.name != "long-word" { #expect(CaptionBreaker.columns(of: line) <= limit, "\(line)") }
                }
            }
        }
    }

    @Test("a cue's text is the segment's words in order, none lost")
    func nothingIsLost() throws {
        let item = try item("long-untimed")
        let said = try srt(item, length: .short).flatMap(\.lines).joined(separator: " ").split(separator: " ")
        #expect(said.map(String.init) == CaptionCueFixtures.longText.split(separator: " ").map(String.init))
    }

    @Test("with word timings a cue runs from its first word to its last and does not cover a pause")
    func wordTimingsPlaceCues() throws {
        let item = try item("long-timed")
        let cues = try srt(item, length: .medium)
        let words = try #require(item.transcript.segments[0].words)
        #expect(abs(cues[0].start - words[0].start) < 0.002)
        #expect(abs(cues[cues.count - 1].end - words[words.count - 1].end) < 0.002)
        let pause = words[24].start - words[23].end
        #expect(pause > 2)
        let spanning = cues.filter { $0.start < words[23].end && $0.end > words[24].start }
        #expect(spanning.isEmpty, "a cue stays up through the pause: \(spanning)")
    }

    @Test("without word timings time is shared by characters inside the segment")
    func proportionalTiming() throws {
        let item = try item("long-untimed")
        let cues = try srt(item, length: .medium)
        #expect(cues[0].start == 10)
        #expect(abs(cues[cues.count - 1].end - 28) < 0.002)
        let lengths = cues.map { $0.lines.joined(separator: " ").count }
        for (cue, characters) in zip(cues, lengths) {
            let expected = 18 * Double(characters) / Double(lengths.reduce(0, +))
            #expect(abs((cue.end - cue.start) - expected) < 1.0)
        }
    }

    @Test("a merged paragraph is split segment by segment, so its silences stay silent")
    func mergedParagraphKeepsMemberTimes() throws {
        let cues = try srt(item("merged-paragraph"), length: .medium)
        #expect(cues.contains { $0.start == 14 })
        #expect(!cues.contains { $0.start < 14 && $0.end > 8.001 && $0.start >= 8 })
        let firstSegmentCues = cues.filter { $0.end <= 8.001 }
        #expect(firstSegmentCues.count == 2)
    }

    @Test("the speaker label sits on the first cue of a segment only and is not counted on the later ones")
    func labelOnFirstCue() throws {
        let item = try item("speakers")
        let cues = try srt(item, length: .medium)
        let labelled = cues.filter { $0.lines[0].hasPrefix("Ada: ") || $0.lines[0].hasPrefix("Grace: ") }
        #expect(labelled.count == 4)
        let text = cues.map { $0.lines.joined(separator: " ") }
        #expect(text.filter { $0.contains("Ada:") }.count == 3)
        #expect(cues.filter { !$0.lines[0].contains(":") }.allSatisfy { $0.lines.joined(separator: " ").split(separator: " ").count > 1 })
    }

    @Test("a VTT voice tag is on every cue of a segment, since it is metadata and takes no width")
    func voiceTagOnEveryCue() throws {
        let item = try item("speakers")
        let text = try Exporters.exporter(for: CaptionCueFixtures.spec(item, format: .vtt, length: .medium)).renderText(item.transcript)
        let cues = text.components(separatedBy: "\n\n").filter { $0.contains("-->") }
        #expect(cues.count == 6)
        #expect(cues.allSatisfy { $0.contains("<v ") && $0.contains("</v>") })
    }

    @Test("a cue gets a second to be read, but never past the next cue")
    func minimumDurationInFiles() throws {
        let cues = try srt(item("very-short"), length: .medium)
        #expect(cues[0].end - cues[0].start == CaptionCues.minCueSeconds)
        #expect(cues[1].end == cues[2].start)
        #expect(cues[1].end - cues[1].start < CaptionCues.minCueSeconds)
        #expect(cues[3].end - cues[3].start >= CaptionCues.minCueSeconds)
    }

    @Test("overlapping segments are trimmed to the start of the next")
    func adjacentSegments() throws {
        let cues = try srt(item("adjacent"), length: .medium)
        for (earlier, later) in zip(cues, cues.dropFirst()) { #expect(earlier.end <= later.start) }
        #expect(cues.contains { $0.end == 4 })
    }

    @Test("Japanese is split by characters, and no line begins with closing punctuation")
    func japaneseSplitsByCharacter() throws {
        let cues = try srt(item("japanese-original"), length: .short)
        #expect(cues.count == 2)
        for line in cues.flatMap(\.lines) {
            #expect(CaptionBreaker.columns(of: line) <= 32)
            #expect(!"。、」）".contains(line.first!))
        }
    }

    private func model(_ item: CaptionCueFixtures.Case, length: CaptionLength) throws -> [CaptionCue] {
        let spec = CaptionCueFixtures.spec(item, format: .srt, length: length)
        let limit = try #require(length.maxCharsPerLine)
        return try CaptionCues.cues(
            for: CaptionCues.sources(from: item.transcript, spec: spec), breaker: .characters(limit), speakerPrefix: { "\($0): " }
        )
    }

    @Test("a translation without spaces is capped and split like the original, not left on one cue")
    func japaneseTranslationIsSplit() throws {
        let cues = try model(item("japanese-both"), length: .short)
        #expect(cues.count == 5)
        for cue in cues { for line in cue.translation { #expect(CaptionBreaker.columns(of: line) <= 32) } }
        #expect(cues.flatMap(\.translation).joined().hasPrefix("今日は"))
        #expect(cues.flatMap(\.translation).joined().hasSuffix("表示されます。"))
        #expect(try srt(item("japanese-translation"), length: .short).count == 2)
    }

    @Test("both languages pair in reading order, one line of each per cue")
    func bothLanguagesPair() throws {
        let cues = try model(item("italian-both"), length: .medium)
        #expect(cues.allSatisfy { $0.lines.count <= 1 && $0.translation.count <= 1 })
        #expect(cues.flatMap(\.lines).joined(separator: " ") == CaptionCueFixtures.longText)
        let italian = cues.flatMap(\.translation).joined(separator: " ")
        #expect(italian.hasPrefix("La cosa") && italian.hasSuffix("in verticale."))
    }

    @Test("a short original with a long translation is not stretched into tiny cues")
    func shortOriginalLongTranslation() throws {
        let cues = try model(item("short-original-long-translation"), length: .medium)
        #expect(cues.count == 2)
        #expect(cues[0].lines == ["Yes, of course."])
        #expect(cues[1].lines.isEmpty && cues[1].translation.count == 2)
        for cue in cues { #expect(cue.end - cue.start >= CaptionCues.minCueSeconds) }
    }

    @Test("a one-word translation does not force the original into one-line cues")
    func oneWordTranslation() throws {
        let cues = try model(item("one-word-translation"), length: .medium)
        #expect(cues[0].translation == ["Sì."])
        #expect(cues.dropFirst().allSatisfy { $0.translation.isEmpty })
        #expect(cues.count < 8)
        #expect(cues.dropFirst().contains { $0.lines.count == 2 })
    }

    @Test("the speaker label takes its share of the first cue's time as well as its width")
    func labelCountsForTime() throws {
        let item = try item("label-width")
        let cues = try model(item, length: .medium)
        #expect(cues.count == 2)
        let unlabelled = try model(CaptionCueFixtures.Case(name: "plain", transcript: item.transcript), length: .medium)
        #expect(unlabelled.count == 1)
        let first = Double(cues[0].lines.joined(separator: " ").count)
        let second = Double(cues[1].lines.joined(separator: " ").count)
        #expect(cues[0].end - cues[0].start > 8 * first / (first + second))
    }

    @Test("a short word beside one that is too long shares its two-line cue instead of flashing alone")
    func longWordSharesTheCue() throws {
        let cues = try srt(item("long-word"), length: .medium)
        #expect(cues.count == 1)
        #expect(cues[0].lines.first == "ok")
        #expect(cues[0].end - cues[0].start >= CaptionCues.minCueSeconds)
    }

    @Test("a zero-length or inverted long segment stays one taller cue, as As-is writes it, and shows for the minimum")
    func zeroLengthSegmentsStayOneCue() throws {
        for name in ["zero-length-long", "start-after-end"] {
            let cues = try model(item(name), length: .medium)
            #expect(cues.count == 1, "\(name)")
            #expect(cues[0].lines.count > 2, "\(name)")
            #expect(cues[0].end - cues[0].start >= CaptionCues.minCueSeconds, "\(name)")
        }
    }

    @Test("two segments that start together both keep their time, and overlap as As-is does")
    func sameStartKeepsBoth() throws {
        let cues = try model(item("same-start"), length: .medium)
        #expect(cues.count == 2)
        for cue in cues {
            #expect(cue.start == 0)
            #expect(cue.end == 6)
        }
    }

    @Test("a segment spoken inside a long one does not cut the long one short")
    func interjectionInsideALongSegment() throws {
        let cues = try model(item("interjection"), length: .medium)
        let outer = cues.filter { $0.lines != ["Mm-hmm."] }
        #expect(outer.last?.end == 20)
        for (earlier, later) in zip(outer, outer.dropFirst()) { #expect(earlier.end == later.start) }
        for cue in outer { #expect(cue.end - cue.start >= CaptionCues.minCueSeconds) }
        let inner = try #require(cues.first { $0.lines == ["Mm-hmm."] })
        #expect(inner.start == 8)
        #expect(inner.end - inner.start >= 0.6)
    }

    @Test("a segment of 10 ms keeps its natural end when the next starts at once, and nothing is clipped below a second")
    func tinySegmentBeforeTheNext() throws {
        let cues = try model(item("tiny-before-next"), length: .medium)
        #expect(cues.count == 2)
        #expect(cues[0].end - cues[0].start <= 0.04)
        #expect(cues[1].end - cues[1].start >= CaptionCues.minCueSeconds)
    }

    @Test("a segment gets at most one cue per minimum duration, however much text it has")
    func cueCountFollowsDuration() throws {
        let long = String(repeating: CaptionCueFixtures.longText + " ", count: 4)
        let transcript = CaptionCueFixtures.transcript([TranscriptSegment(id: 0, start: 0, end: 3.5, text: long)])
        let spec = ExportSpec.srt(captionLength: .short)
        let cues = try CaptionCues.cues(
            for: CaptionCues.sources(from: transcript, spec: spec), breaker: .characters(32), speakerPrefix: { $0 }
        )
        #expect(cues.count == 1)
        #expect(cues[0].lines.count > 2)
        let fewer = CaptionCueFixtures.transcript([TranscriptSegment(id: 0, start: 0, end: 3.5, text: CaptionCueFixtures.longText.prefix(120).description)])
        let split = try CaptionCues.cues(for: CaptionCues.sources(from: fewer, spec: spec), breaker: .characters(32), speakerPrefix: { $0 })
        #expect(split.count <= 3)
        for cue in split { #expect(cue.end - cue.start >= CaptionCues.minCueSeconds - 1e-9) }
    }

    @Test("a small kana or the prolonged sound mark never starts a line or a cue")
    func smallKanaStaysWithTheCharacterBefore() throws {
        let text = String(repeating: "キャッシュを消してちょっと待ってください。ラーメンとコーヒーをお願いします。", count: 3)
        let transcript = CaptionCueFixtures.transcript([TranscriptSegment(id: 0, start: 0, end: 30, text: text)], language: "ja")
        for length in [CaptionLength.short, .medium, .long] {
            let cues = try CaptionCues.cues(
                for: CaptionCues.sources(from: transcript, spec: .srt(captionLength: length)),
                breaker: .characters(length.maxCharsPerLine!), speakerPrefix: { $0 }
            )
            #expect(cues.count >= 1)
            for line in cues.flatMap(\.lines) { #expect(!CaptionScript.closers.contains(line.first!), "\(line)") }
            #expect(cues.flatMap(\.lines).joined() == text)
        }
    }

    @Test("Japanese cuts fall between words, not inside them")
    func japaneseCutsAtWords() throws {
        let cues = try model(item("japanese-original"), length: .short)
        let lines = cues.flatMap(\.lines)
        #expect(!lines.contains { $0.hasSuffix("説明しま") })
        #expect(lines.joined() == "今日は新しい字幕の分割について説明します。長い文章は読みやすい長さに切り、話している間だけ画面に表示されます。")
    }

    @Test("encode, called with a prepared transcript, writes the same cues as render when nothing is merged")
    func encodeMatchesRender() throws {
        let item = try item("speakers")
        let spec = CaptionCueFixtures.spec(item, format: .srt, length: .medium)
        let exporter = SrtExporter(spec: spec)
        #expect(try exporter.encode(spec.prepared(item.transcript)) == exporter.render(item.transcript))
        let vtt = VttExporter(spec: CaptionCueFixtures.spec(item, format: .vtt, length: .medium))
        #expect(try vtt.encode(vtt.spec.prepared(item.transcript)) == vtt.render(item.transcript))
    }

    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }

    @Test("no split cue is shown for less than the minimum, whether timed by words, by characters or beside a translation")
    func splitCuesKeepTheMinimum() throws {
        var random = SplitMix(state: 7)
        let vocabulary = CaptionCueFixtures.longText.split(separator: " ").map(String.init)
        var checked = 0
        for round in 0..<300 {
            var sources: [CaptionSource] = []
            var clock = 0.0
            for id in 0..<4 {
                let words = (0..<Int.random(in: 1...45, using: &random)).map { _ in vocabulary.randomElement(using: &random)! }
                let text = words.joined(separator: " ")
                let span = Double.random(in: 0.4...14, using: &random)
                var timings: [WordTiming]?
                if round % 3 == 0 {
                    var at = clock
                    timings = words.enumerated().map { index, word in
                        defer { at += Double.random(in: 0.1...0.5, using: &random) + (Int.random(in: 0..<12, using: &random) == 0 ? 2 : 0) }
                        return WordTiming(id: "\(id)-\(index)", word: word, start: at, end: at + 0.1, probability: 1)
                    }
                }
                let end = max(clock + span, (timings?.last?.end ?? 0))
                let translation = round % 3 == 1 ? words.reversed().joined(separator: " ") : nil
                sources.append(CaptionSource(
                    parts: [CaptionSource.Part(text: text, start: clock, end: end, words: timings, translation: translation)],
                    speaker: nil, tag: id
                ))
                clock = end + Double.random(in: 0...3, using: &random)
            }
            let cues = try CaptionCues.cues(for: sources, breaker: .characters(42), speakerPrefix: { $0 })
            for id in 0..<4 {
                let own = cues.filter { $0.tag == id }
                guard own.count > 1 else { continue }
                for cue in own {
                    checked += 1
                    #expect(cue.end - cue.start >= CaptionCues.minCueSeconds - 1e-6, "round \(round) segment \(id): \(cue.end - cue.start)")
                }
            }
        }
        #expect(checked > 200)
    }

    @Test("no Japanese line begins with ASCII punctuation, whatever the text and the limit")
    func japaneseLinesDoNotOpenWithPunctuation() throws {
        var random = SplitMix(state: 11)
        let pieces = ["今日は", "新しい", "字幕", "を", "買いました", "待ってください", "それでは", "キャッシュ", "ちょっと", "本当ですか", "説明します"]
        let marks = ["", "。", "、", "!", "?", ",", ".", ")", ":"]
        for _ in 0..<200 {
            let text = (0..<Int.random(in: 4...30, using: &random)).map { _ in
                pieces.randomElement(using: &random)! + marks.randomElement(using: &random)!
            }.joined()
            let transcript = CaptionCueFixtures.transcript([TranscriptSegment(id: 0, start: 0, end: 60, text: text)], language: "ja")
            for length in [CaptionLength.short, .medium, .long] {
                let lines = try CaptionCues.cues(
                    for: CaptionCues.sources(from: transcript, spec: .srt(captionLength: length)),
                    breaker: .characters(length.maxCharsPerLine!), speakerPrefix: { $0 }
                ).flatMap(\.lines)
                #expect(lines.joined() == text)
                for line in lines { #expect(!"?!.,:;)".contains(line.first!) && !CaptionScript.closers.contains(line.first!), "\(line)") }
            }
        }
    }

    @Test("As-is output does not split, merge or retime anything")
    func asIsUntouched() throws {
        let long = CaptionCueFixtures.transcript([TranscriptSegment(id: 0, start: 1, end: 20, text: CaptionCueFixtures.longText)])
        let output = try SrtExporter(spec: .srt()).renderText(long)
        #expect(output == "1\n00:00:01,000 --> 00:00:20,000\n\(CaptionCueFixtures.longText)\n\n")
    }

    private func burnCues(_ item: CaptionCueFixtures.Case, width: CGFloat) throws -> [BurnCue] {
        let options = CaptionCueFixtures.spec(item, format: .srt, length: .medium).options
        let size = CGSize(width: width, height: width * 9 / 16)
        let metrics = SubtitleBurner.CaptionMetrics(style: SubtitleBurner.Style(), renderSize: size)
        return try SubtitleBurner.cues(from: item.transcript, options: options, metrics: metrics, renderSize: size)
    }

    @Test("the burn packs, times and labels cues as the export does; only where a line breaks can differ")
    func burnAgreesWithExport() throws {
        for item in CaptionCueFixtures.cases {
            let burn = try burnCues(item, width: 1920)
            let exported = try srt(item, length: .medium)
            #expect(burn.count == exported.count, "\(item.name)")
        }
        for name in ["very-short", "merged-paragraph", "speakers", "long-untimed", "long-timed", "italian-both", "japanese-original"] {
            let item = try item(name)
            let burn = try burnCues(item, width: 1920)
            let exported = try srt(item, length: .medium)
            #expect(burn.map(\.text) == exported.map { $0.lines.joined(separator: "\n") }, "\(name)")
            for (cue, written) in zip(burn, exported) {
                #expect(abs(cue.start - written.start) < 0.001 && abs(cue.end - written.end) < 0.001, "\(name)")
            }
        }
    }

    @Test("no burn line wraps in a narrow frame behind a long speaker label, even with merged Japanese words")
    func narrowFrameNeverWraps() throws {
        let text = String(repeating: "昨日は本を買いました。それでは待ってください。そうなんですよね", count: 3)
        let transcript = CaptionCueFixtures.transcript(
            [TranscriptSegment(id: 0, start: 0, end: 30, text: text, speaker: "Interviewer Number One")], language: "ja"
        )
        var options = ExportSpec.srt(captionLength: .medium).options
        options.captionLength = .medium
        options.speakers = true
        for width in [CGFloat(480), 720] {
            let size = CGSize(width: width, height: width * 9 / 16)
            let metrics = SubtitleBurner.CaptionMetrics(style: SubtitleBurner.Style(), renderSize: size)
            let font = Format.cascadingFont(name: metrics.fontName, size: metrics.fontSize, language: "ja")
            let built = try SubtitleBurner.cues(from: transcript, options: options, metrics: metrics, renderSize: size)
            for line in built.flatMap({ $0.text.split(separator: "\n").map(String.init) }) {
                #expect(SubtitleBurner.wrappedLines(line, font: font, maxWidth: width - metrics.horizontalInset * 2).count == 1, "\(line)")
            }
        }
    }

    @Test("a narrow frame gives cues of one Core Text line each when the caption length is short")
    func burnBreaksByWidth() throws {
        let cues = try burnCues(item("long-untimed"), width: 720)
        let metrics = SubtitleBurner.CaptionMetrics(style: SubtitleBurner.Style(), renderSize: CGSize(width: 720, height: 405))
        let font = Format.cascadingFont(name: metrics.fontName, size: metrics.fontSize, language: "en")
        for cue in cues {
            for line in cue.text.split(separator: "\n") {
                #expect(SubtitleBurner.wrappedLines(String(line), font: font, maxWidth: 720 - metrics.horizontalInset * 2).count == 1)
            }
        }
    }

    @Test("QC judges the segment by the cues the export writes")
    func qcAgreesWithExport() throws {
        let segment = TranscriptSegment(id: 0, start: 10, end: 28, text: CaptionCueFixtures.longText)
        #expect(SubtitleQC.issues(for: segment, captionLength: .medium).isEmpty)
        let hurried = TranscriptSegment(id: 0, start: 0, end: 3, text: CaptionCueFixtures.longText)
        #expect(SubtitleQC.issues(for: hurried, captionLength: .medium).contains { if case .tooFast = $0 { true } else { false } })
        let word = String(repeating: "a", count: 50)
        #expect(SubtitleQC.issues(text: "ok \(word)", duration: 20, captionLength: .medium) == [.lineTooLong(limit: 42)])
    }

    @Test("QC does not flag a long segment as one tall, fast cue")
    func qcUsesPerCueSpeed() {
        let segment = TranscriptSegment(id: 0, start: 0, end: 18, text: CaptionCueFixtures.longText)
        #expect(SubtitleQC.issues(for: segment, captionLength: .short).isEmpty)
    }

    @Test("Thai is cut at word boundaries, not inside a word, and loses no character")
    func thai() throws {
        let thai = String(repeating: "วันนี้อากาศดีมากเราไปเดินเล่นที่สวนสาธารณะกันเถอะ", count: 3)
        let atoms = CaptionAtom.atoms(in: thai)
        #expect(atoms.map(\.text).joined() == thai)
        #expect(atoms.count > 3)
        let item = CaptionCueFixtures.Case(name: "thai", transcript: CaptionCueFixtures.transcript([TranscriptSegment(id: 0, start: 0, end: 12, text: thai)], language: "th"))
        let cues = try srt(item, length: .short)
        #expect(cues.flatMap(\.lines).joined() == thai)
        #expect(cues.flatMap(\.lines).allSatisfy { $0.count <= 32 })
    }

    @Test("a four-hundred-word segment splits quickly")
    func largeSegmentIsFast() throws {
        let text = Array(repeating: CaptionCueFixtures.longText, count: 8).joined(separator: " ")
        let item = CaptionCueFixtures.Case(name: "big", transcript: CaptionCueFixtures.transcript([TranscriptSegment(id: 0, start: 0, end: 600, text: text)]))
        let started = Date()
        let cues = try srt(item, length: .medium)
        #expect(cues.count > 20)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
