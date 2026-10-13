import Foundation
import Testing
@testable import ParolaCore

@Suite("Caption cues")
struct CaptionCuesTests {
    @Test("atoms keep spaced words whole and never begin with closing punctuation or a small kana")
    func atoms() {
        func texts(_ s: String) -> [String] { CaptionAtom.atoms(in: s).map(\.text) }
        #expect(texts("Hello, world") == ["Hello,", "world"])
        let mixed = CaptionAtom.atoms(in: "Parola は")
        #expect(mixed.map(\.spaceBefore) == [false, true])
        #expect(CaptionAtom.atoms(in: "  \n ").isEmpty)
        for text in ["今日は、「晴れ」です。", "キャッシュを消してちょっと待ってください。", "ちょっと、ちょっ！ラーメンをください。ヴァイオリンのソロ"] {
            let atoms = CaptionAtom.atoms(in: text, language: "ja")
            #expect(atoms.map(\.text).joined() == text)
            for atom in atoms.dropFirst() { #expect(!CaptionScript.closers.contains(atom.text.first!), "\(atoms.map(\.text)))") }
            for atom in atoms { for piece in atom.exploded().dropFirst() { #expect(!CaptionScript.closers.contains(piece.text.first!)) } }
        }
    }

    @Test("Chinese words stay whole: 显示 is one atom")
    func chineseWords() {
        let atoms = CaptionAtom.atoms(in: "这个字幕显示得更好看，而且更容易阅读。", language: "zh")
        #expect(atoms.map(\.text).joined() == "这个字幕显示得更好看，而且更容易阅读。")
        #expect(atoms.contains { $0.text.contains("显示") })
        #expect(!atoms.contains { $0.text.hasSuffix("显") })
    }

    @Test("Japanese endings stay with their word: 買いました。 and について are one atom each")
    func japaneseWords() {
        let sentence = "分割について説明します。読みやすい長さに切ります。昨日は本を買いました。待ってください!それでは"
        let atoms = CaptionAtom.atoms(in: sentence, language: "ja").map(\.text)
        #expect(atoms.joined() == sentence)
        #expect(atoms.contains("分割について"))
        #expect(atoms.contains("説明します。"))
        #expect(atoms.contains { $0.hasSuffix("買いました。") })
        #expect(atoms.contains("待ってください!"))
        #expect(atoms.contains("読みやすい"))
        #expect(!atoms.contains { "?!.,:;)".contains($0.first!) })
    }

    @Test("a closer is attached to the last word before it even when the one between was emptied")
    func closerLooksBackPastEmptiedPieces() {
        let text = "リっ。ーはす"
        let atoms = CaptionAtom.atoms(in: text, language: "ja")
        #expect(atoms.map(\.text).joined() == text)
        for atom in atoms { #expect(!CaptionScript.closers.contains(atom.text.first!), "\(atoms.map(\.text))") }
    }

    @Test("a casual sentence with no kanji is not glued into one long atom, and is cut between its words")
    func casualSentenceSplitsAtSeams() throws {
        let text = "そうなんですよねだからやっぱりそういうことなんですけどね"
        let atoms = CaptionAtom.atoms(in: text, language: "ja")
        #expect(atoms.map(\.text).joined() == text)
        #expect(atoms.count > 4)
        #expect(atoms.allSatisfy { $0.text.count <= 10 })
        var boundaries = Set<Int>()
        var at = 0
        for atom in atoms { at += atom.text.count; boundaries.insert(at) }
        let transcript = CaptionCueFixtures.transcript([TranscriptSegment(id: 0, start: 0, end: 10, text: text)], language: "ja")
        let cues = try CaptionCues.cues(
            for: CaptionCues.sources(from: transcript, spec: .srt(captionLength: .short)), breaker: .characters(16), speakerPrefix: { $0 }
        )
        var cut = 0
        for line in cues.flatMap(\.lines).dropLast() {
            cut += line.count
            #expect(boundaries.contains(cut), "cut at \(cut) inside a word")
        }
    }

    @Test("an over-wide merged atom is cut at its word seams before it is cut by character")
    func seamsBeforeCharacters() {
        let atom = CaptionAtom(text: "買いました", spaceBefore: false, offset: 0, seams: [2, 4])
        #expect(atom.exploded().map(\.text) == ["買い", "まし", "た"])
    }

    @Test("a short cue extended to the minimum does not outlive the cue it sits inside")
    func extensionStaysInsideTheOuterCue() {
        let cues = CaptionCues.settle([
            CaptionCue(start: 0, end: 5, lines: ["outer"], translation: [], speaker: nil, voice: nil, source: 0),
            CaptionCue(start: 4.6, end: 4.8, lines: ["inner"], translation: [], speaker: nil, voice: nil, source: 1),
        ])
        #expect(cues[1].end == 5)
    }

    @Test("an over-wide atom is cut by character, each piece keeping the offset of the characters before it")
    func explodedAtom() {
        let atom = CaptionAtom.atoms(in: "分割について", language: "ja")[0]
        let pieces = atom.exploded()
        #expect(pieces.map(\.text).joined() == atom.text)
        var expected = atom.offset
        for piece in pieces {
            #expect(piece.offset == expected)
            expected += piece.text.count
        }
    }

    @Test("ASCII punctuation after Japanese text never starts an atom")
    func asciiPunctuationClosesAJapaneseWord() {
        for text in ["本当ですか?はい!", "待って,ください.", "ええ;そう:です)"] {
            let atoms = CaptionAtom.atoms(in: text, language: "ja")
            #expect(atoms.map(\.text).joined() == text)
            for atom in atoms { #expect(!"?!.,:;)".contains(atom.text.first!), "\(atoms.map(\.text))") }
            for atom in atoms { for piece in atom.exploded().dropFirst() { #expect(!"?!.,:;)".contains(piece.text.first!)) } }
        }
    }

    @Test("a short gap between a segment's cues is closed, a long one is kept")
    func gapsInsideASegment() {
        let cues = CaptionCues.settle([
            CaptionCue(start: 0, end: 2, lines: ["a"], translation: [], speaker: nil, voice: nil, source: 0),
            CaptionCue(start: 2.6, end: 4, lines: ["b"], translation: [], speaker: nil, voice: nil, source: 0),
            CaptionCue(start: 6, end: 8, lines: ["c"], translation: [], speaker: nil, voice: nil, source: 0),
            CaptionCue(start: 8.4, end: 10, lines: ["d"], translation: [], speaker: nil, voice: nil, source: 1),
        ])
        #expect(cues.map(\.end) == [2.6, 4, 8, 10])
    }

    @Test("a zero-length or inverted segment still gets a cue that shows")
    func degenerateSegments() {
        let cues = CaptionCues.settle([
            CaptionCue(start: 3, end: 3, lines: ["a"], translation: [], speaker: nil, voice: nil, source: 0),
            CaptionCue(start: 8, end: 2, lines: ["b"], translation: [], speaker: nil, voice: nil, source: 1),
        ])
        #expect(cues.allSatisfy { $0.end > $0.start })
    }

    @Test("a cue gets a second to be read, but never past the next cue")
    func minimumDuration() {
        let cues = CaptionCues.settle([
            CaptionCue(start: 1, end: 1.3, lines: ["a"], translation: [], speaker: nil, voice: nil, source: 0),
            CaptionCue(start: 5, end: 5.2, lines: ["b"], translation: [], speaker: nil, voice: nil, source: 1),
            CaptionCue(start: 5.6, end: 5.7, lines: ["c"], translation: [], speaker: nil, voice: nil, source: 2),
        ])
        #expect(cues[0].end - cues[0].start == CaptionCues.minCueSeconds)
        #expect(cues[1].end == cues[2].start)
        #expect(cues[2].end - cues[2].start == CaptionCues.minCueSeconds)
    }

    @Test("cues are packed into at most two lines, evened out, in a single pass over the atoms")
    func packing() {
        let atoms = CaptionAtom.atoms(in: "Hello everyone welcome back today")
        let packer = CaptionPacker(atoms: atoms, measure: CaptionBreaker.characters(32).measure(atoms, ""))
        let groups = packer.groups(prefixed: false, maxLines: 2)
        #expect(groups.count == 1)
        #expect(packer.lines(groups[0], prefixed: false, maxLines: 2) == ["Hello everyone", "welcome back today"])
    }
}
