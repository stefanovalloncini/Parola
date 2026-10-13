import Foundation
import NaturalLanguage

/// A piece of caption text that may start a line: a word, which for Chinese, Japanese and Thai is a dictionary word.
struct CaptionAtom: Equatable {
    var text: String
    var spaceBefore: Bool
    var offset: Int
    var columns: Int
    /// Character positions inside the text where the tokenizer saw one word end and the next begin.
    var seams: [Int]

    init(text: String, spaceBefore: Bool, offset: Int, seams: [Int] = []) {
        self.text = text
        self.spaceBefore = spaceBefore
        self.offset = offset
        self.seams = seams
        columns = CaptionBreaker.columns(of: text)
    }

    static func atoms(in text: String, language: String? = nil, tokenizer: CaptionTokenizer = CaptionTokenizer()) -> [CaptionAtom] {
        var builder = AtomBuilder(tokenizer: tokenizer, language: language)
        for character in text { builder.add(character) }
        return builder.finish()
    }

    /// The atom cut at its word seams, or one atom per character when it has none; closing punctuation and small kana stay with the character before.
    func exploded() -> [CaptionAtom] {
        var pieces: [String] = []
        if seams.isEmpty {
            for character in text {
                if !pieces.isEmpty, CaptionScript.isCloser(character) {
                    pieces[pieces.count - 1].append(character)
                } else {
                    pieces.append(String(character))
                }
            }
        } else {
            let characters = Array(text)
            let cuts = [0] + seams.filter { $0 > 0 && $0 < characters.count } + [characters.count]
            pieces = zip(cuts, cuts.dropFirst()).map { String(characters[$0..<$1]) }
        }
        var offset = self.offset
        return pieces.enumerated().map { index, piece in
            defer { offset += piece.count }
            return CaptionAtom(text: piece, spaceBefore: index == 0 && spaceBefore, offset: offset)
        }
    }

    var hasUnspacedScript: Bool { text.contains { CaptionScript.kind(of: $0) == .unspaced } }
}

/// Finds word boundaries in scripts written without spaces. One per export, so its dictionaries load once.
final class CaptionTokenizer {
    private var tokenizer: NLTokenizer?
    private var language: String?

    func words(in run: String, language: String?) -> [String] {
        let tokenizer = self.tokenizer ?? NLTokenizer(unit: .word)
        if self.tokenizer == nil || self.language != language {
            tokenizer.setLanguage(language.map { NLLanguage(rawValue: $0) } ?? .undetermined)
            self.language = language
        }
        self.tokenizer = tokenizer
        tokenizer.string = run
        var starts: [String.Index] = []
        tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { range, _ in
            starts.append(range.lowerBound)
            return true
        }
        guard !starts.isEmpty else { return [run] }
        starts[0] = run.startIndex
        let ends = starts.dropFirst() + [run.endIndex]
        return zip(starts, ends).map { String(run[$0..<$1]) }
    }
}

enum CaptionScript {
    enum Kind { case spaced, unspaced, closer, opener }

    /// Characters that never begin a line: closing punctuation, small kana, the prolonged sound mark and iteration marks.
    static let closers = Set("、。，．）」』】〉》〕！？：；・ー…々ゝゞヽヾぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ")
    static let openers = Set("（「『【〈《〔")
    /// ASCII punctuation that follows a Chinese, Japanese or Thai word closes it rather than starting a word.
    static let asciiClosers = Set("?!.,:;)")

    static func isCloser(_ character: Character) -> Bool {
        closers.contains(character) || asciiClosers.contains(character)
    }

    static func isHiraganaOnly(_ text: String) -> Bool {
        text.allSatisfy { character in
            isCloser(character) || character.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
        }
    }

    /// Whether a hiragana ending joins this word: it needs kanji or katakana to hang on, must not close a clause, and must be short of ten characters.
    static func takesEnding(_ text: String) -> Bool {
        guard text.count < 10, !(text.last.map { "。！？!?、，,".contains($0) } ?? false) else { return false }
        return text.unicodeScalars.contains { !(0x3040...0x309F).contains($0.value) && kind(of: Character($0)) == .unspaced }
    }

    static func kind(of character: Character) -> Kind {
        if character.isASCII { return .spaced }
        if closers.contains(character) { return .closer }
        if openers.contains(character) { return .opener }
        guard let value = character.unicodeScalars.first?.value else { return .spaced }
        switch value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF, 0xFF66...0xFF9F,
             0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF:
            return .unspaced
        default:
            return .spaced
        }
    }
}

private struct AtomBuilder {
    private let tokenizer: CaptionTokenizer
    private let language: String?
    private var atoms: [CaptionAtom] = []
    private var word = ""
    private var wordHasSpaceBefore = false
    private var run = ""
    private var runHasSpaceBefore = false
    private var pendingSpace = false
    private var offset = 0

    init(tokenizer: CaptionTokenizer, language: String?) {
        self.tokenizer = tokenizer
        self.language = language
    }

    mutating func add(_ character: Character) {
        if character.isWhitespace {
            flush()
            pendingSpace = true
            return
        }
        switch CaptionScript.kind(of: character) {
        case .spaced:
            if !run.isEmpty, !pendingSpace, CaptionScript.asciiClosers.contains(character) {
                run.append(character)
                return
            }
            flushRun()
            if word.isEmpty { wordHasSpaceBefore = pendingSpace; pendingSpace = false }
            word.append(character)
        case .unspaced, .opener:
            flushWord()
            addToRun(character)
        case .closer:
            if !word.isEmpty {
                word.append(character)
            } else if run.isEmpty, !pendingSpace, !atoms.isEmpty {
                atoms[atoms.count - 1].text.append(character)
                atoms[atoms.count - 1].columns = CaptionBreaker.columns(of: atoms[atoms.count - 1].text)
                offset += 1
            } else {
                addToRun(character)
            }
        }
    }

    mutating func finish() -> [CaptionAtom] {
        flush()
        return atoms
    }

    private mutating func addToRun(_ character: Character) {
        if run.isEmpty { runHasSpaceBefore = pendingSpace; pendingSpace = false }
        run.append(character)
    }

    private mutating func flush() {
        flushWord()
        flushRun()
    }

    private mutating func flushWord() {
        guard !word.isEmpty else { return }
        emit(word, spaceBefore: wordHasSpaceBefore)
        word = ""
    }

    private mutating func flushRun() {
        guard !run.isEmpty else { return }
        var spaceBefore = runHasSpaceBefore
        for piece in Self.settled(tokenizer.words(in: run, language: language)) {
            emit(piece.text, spaceBefore: spaceBefore, seams: piece.seams)
            spaceBefore = false
        }
        run = ""
    }

    private mutating func emit(_ text: String, spaceBefore: Bool, seams: [Int] = []) {
        atoms.append(CaptionAtom(text: text, spaceBefore: spaceBefore && !atoms.isEmpty, offset: offset, seams: seams))
        offset += text.count
    }

    /// Moves closing punctuation back to the word before it and opening brackets on to the next, and joins the hiragana endings the tokenizer splits off (買い|まし|た) onto a word with kanji or katakana.
    private static func settled(_ words: [String]) -> [(text: String, seams: [Int])] {
        var pieces = words
        for index in pieces.indices.dropFirst() {
            while let first = pieces[index].first, CaptionScript.isCloser(first),
                  let before = pieces[..<index].lastIndex(where: { !$0.isEmpty }) {
                pieces[before].append(first)
                pieces[index].removeFirst()
            }
        }
        for index in pieces.indices.dropLast().reversed() {
            while let last = pieces[index].last, CaptionScript.openers.contains(last) {
                pieces[index + 1].insert(last, at: pieces[index + 1].startIndex)
                pieces[index].removeLast()
            }
        }
        var merged: [(text: String, seams: [Int])] = []
        for piece in pieces where !piece.isEmpty {
            if let last = merged.last, CaptionScript.isHiraganaOnly(piece), CaptionScript.takesEnding(last.text) {
                merged[merged.count - 1] = (last.text + piece, last.seams + [last.text.count])
            } else {
                merged.append((piece, []))
            }
        }
        return merged
    }
}

/// How wide a line of atoms is and whether it fits, bound to one list of atoms and the text that sits before its first line.
protocol CaptionMeasure {
    func width(_ range: Range<Int>, prefixed: Bool) -> Double
    func fits(_ range: Range<Int>, prefixed: Bool) -> Bool
}

/// Decides what fits on a caption line: character columns for a file, Core Text for the burn.
struct CaptionBreaker {
    let measure: (_ atoms: [CaptionAtom], _ prefix: String) -> any CaptionMeasure

    static func characters(_ limit: Int) -> CaptionBreaker {
        CaptionBreaker { atoms, prefix in ColumnMeasure(atoms: atoms, prefixColumns: columns(of: prefix), limit: limit) }
    }

    /// Adds up per-atom advances a renderer measured once, so a segment is packed without measuring a line; `limit` is the width a line may take.
    static func advances(
        limit: Double, characterLimit: Int, spaceAdvance: Double, advance: @escaping (String) -> Double
    ) -> CaptionBreaker {
        CaptionBreaker { atoms, prefix in
            AdvanceMeasure(
                atoms: atoms, prefixAdvance: prefix.isEmpty ? 0 : advance(prefix), prefixColumns: columns(of: prefix),
                limit: limit, characterLimit: characterLimit, spaceAdvance: spaceAdvance, advance: advance
            )
        }
    }

    /// The width of a line in character columns: a full-width character takes two, as it does on screen.
    static func columns(of line: String) -> Int {
        let asciiCount = line.utf8.withContiguousStorageIfAvailable { $0.allSatisfy { $0 < 0x80 } ? $0.count : -1 }
        if let asciiCount, asciiCount >= 0 { return asciiCount }
        var total = 0
        for character in line {
            total += isFullWidth(character) ? 2 : 1
        }
        return total
    }

    private static func isFullWidth(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value, value >= 0x1100 else { return false }
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

/// Widths from prefix sums, so any run of atoms is measured without building its text.
private struct ColumnMeasure: CaptionMeasure {
    private let cumulative: [Int]
    private let leadingSpace: [Int]
    private let prefixColumns: Int
    private let limit: Int

    init(atoms: [CaptionAtom], prefixColumns: Int, limit: Int) {
        var sums = [0]
        var leads: [Int] = []
        sums.reserveCapacity(atoms.count + 1)
        for (index, atom) in atoms.enumerated() {
            let lead = atom.spaceBefore && index > 0 ? 1 : 0
            leads.append(lead)
            sums.append(sums[index] + atom.columns + lead)
        }
        cumulative = sums
        leadingSpace = leads
        self.prefixColumns = prefixColumns
        self.limit = limit
    }

    func width(_ range: Range<Int>, prefixed: Bool) -> Double {
        Double(cumulative[range.upperBound] - cumulative[range.lowerBound] - leadingSpace[range.lowerBound]
            + (prefixed ? prefixColumns : 0))
    }

    func fits(_ range: Range<Int>, prefixed: Bool) -> Bool {
        width(range, prefixed: prefixed) <= Double(limit)
    }
}

private struct AdvanceMeasure: CaptionMeasure {
    private let widths: [Double]
    private let columns: [Int]
    private let leadingSpace: [Double]
    private let leadingColumn: [Int]
    private let prefixAdvance: Double
    private let prefixColumns: Int
    private let limit: Double
    private let characterLimit: Int

    init(
        atoms: [CaptionAtom], prefixAdvance: Double, prefixColumns: Int, limit: Double, characterLimit: Int,
        spaceAdvance: Double, advance: (String) -> Double
    ) {
        var widths = [0.0]
        var columns = [0]
        var leadWidths: [Double] = []
        var leadColumns: [Int] = []
        for (index, atom) in atoms.enumerated() {
            let space = atom.spaceBefore && index > 0
            leadWidths.append(space ? spaceAdvance : 0)
            leadColumns.append(space ? 1 : 0)
            widths.append(widths[index] + advance(atom.text) + leadWidths[index])
            columns.append(columns[index] + atom.columns + leadColumns[index])
        }
        self.widths = widths
        self.columns = columns
        leadingSpace = leadWidths
        leadingColumn = leadColumns
        self.prefixAdvance = prefixAdvance
        self.prefixColumns = prefixColumns
        self.limit = limit
        self.characterLimit = characterLimit
    }

    func width(_ range: Range<Int>, prefixed: Bool) -> Double {
        widths[range.upperBound] - widths[range.lowerBound] - leadingSpace[range.lowerBound] + (prefixed ? prefixAdvance : 0)
    }

    func fits(_ range: Range<Int>, prefixed: Bool) -> Bool {
        let used = columns[range.upperBound] - columns[range.lowerBound] - leadingColumn[range.lowerBound] + (prefixed ? prefixColumns : 0)
        return used <= characterLimit && width(range, prefixed: prefixed) <= limit
    }
}

/// Cuts a list of atoms into cues of at most `maxLines` lines, evened out so no cue ends on a stray word.
struct CaptionPacker {
    let atoms: [CaptionAtom]
    let measure: any CaptionMeasure

    static func text(_ atoms: [CaptionAtom], _ range: Range<Int>) -> String {
        var out = ""
        for index in range {
            if index > range.lowerBound, atoms[index].spaceBefore { out += " " }
            out += atoms[index].text
        }
        return out
    }

    func text(_ range: Range<Int>) -> String { Self.text(atoms, range) }

    /// The lines a cue shows; the first starts after the speaker label when `prefixed`.
    func lines(_ range: Range<Int>, prefixed: Bool, maxLines: Int) -> [String] {
        guard case .split(let cut)? = layout(range, prefixed: prefixed, maxLines: maxLines) else { return [text(range)] }
        return [text(range.lowerBound..<cut), text(cut..<range.upperBound)]
    }

    /// Cues as few as the limit allows, evened out so none ends on a stray word. A cue never runs across an atom in `breaks`.
    func groups(
        in bounds: Range<Int>? = nil, prefixed: Bool, maxLines: Int, breaks: [Int] = []
    ) -> [Range<Int>] {
        let bounds = bounds ?? 0..<atoms.count
        let edges = [bounds.lowerBound] + breaks.filter { $0 > bounds.lowerBound && $0 < bounds.upperBound }.sorted() + [bounds.upperBound]
        guard edges.count > 2 else { return balanced(bounds, prefixed: prefixed, maxLines: maxLines) }
        return zip(edges, edges.dropFirst()).enumerated().flatMap { index, edge in
            balanced(edge.0..<edge.1, prefixed: prefixed && index == 0, maxLines: maxLines)
        }
    }

    /// The whole range as one taller cue, its lines evened out at the narrowest width that keeps their number.
    func wrapped(_ range: Range<Int>, prefixed: Bool) -> [String] {
        let fewest = lineRanges(range, prefixed: prefixed, budget: .infinity)
        var low = 0.0
        var high = fewest.enumerated().map { measure.width($1, prefixed: prefixed && $0 == 0) }.max() ?? 0
        while high - low > 1 {
            let middle = (low + high) / 2
            if lineRanges(range, prefixed: prefixed, budget: middle).count <= fewest.count { high = middle } else { low = middle }
        }
        return lineRanges(range, prefixed: prefixed, budget: high).map(text)
    }

    private enum Layout { case single, split(Int) }

    private func layout(_ range: Range<Int>, prefixed: Bool, maxLines: Int) -> Layout? {
        if range.count == 1 || measure.fits(range, prefixed: prefixed) { return .single }
        guard maxLines >= 2 else { return nil }
        let first = range.lowerBound
        let last = range.upperBound
        var low = first + 1
        var high = last - 1
        while low < high {
            let middle = (low + high) / 2
            if measure.width(first..<middle, prefixed: prefixed) >= measure.width(middle..<last, prefixed: false) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        var best: (cut: Int, widest: Double)?
        for cut in [low - 1, low, first + 1, last - 1] where cut > first && cut < last {
            guard lineFits(first..<cut, prefixed: prefixed), lineFits(cut..<last, prefixed: false) else { continue }
            let widest = max(measure.width(first..<cut, prefixed: prefixed), measure.width(cut..<last, prefixed: false))
            if best.map({ widest < $0.widest }) ?? true { best = (cut, widest) }
        }
        return best.map { .split($0.cut) }
    }

    private func lineFits(_ range: Range<Int>, prefixed: Bool) -> Bool {
        range.count == 1 || measure.fits(range, prefixed: prefixed)
    }

    private func balanced(_ bounds: Range<Int>, prefixed: Bool, maxLines: Int) -> [Range<Int>] {
        guard !bounds.isEmpty else { return [] }
        let fewest = greedy(bounds, prefixed: prefixed, maxLines: maxLines, budget: .infinity)
        let wanted = fewest.count
        guard wanted > 1 else { return fewest }
        let total = measure.width(bounds, prefixed: prefixed)
        var low = max(0, (total - Double(wanted - 1)) / Double(wanted) - 1)
        var high = fewest.enumerated().map { measure.width($1, prefixed: prefixed && $0 == 0) }.max() ?? 0
        while high - low > 1 {
            let middle = (low + high) / 2
            if greedy(bounds, prefixed: prefixed, maxLines: maxLines, budget: middle).count <= wanted { high = middle } else { low = middle }
        }
        return greedy(bounds, prefixed: prefixed, maxLines: maxLines, budget: high)
    }

    private func greedy(_ bounds: Range<Int>, prefixed: Bool, maxLines: Int, budget: Double) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var first = bounds.lowerBound
        while first < bounds.upperBound {
            let lead = prefixed && groups.isEmpty
            let end = furthest(from: first, to: bounds.upperBound) { candidate in
                layout(candidate, prefixed: lead, maxLines: maxLines) != nil
                    && (budget == .infinity || measure.width(candidate, prefixed: lead) <= budget)
            }
            groups.append(first..<end)
            first = end
        }
        return groups
    }

    private func lineRanges(_ bounds: Range<Int>, prefixed: Bool, budget: Double) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var first = bounds.lowerBound
        while first < bounds.upperBound {
            let lead = prefixed && lines.isEmpty
            let end = furthest(from: first, to: bounds.upperBound) { candidate in
                measure.fits(candidate, prefixed: lead) && (budget == .infinity || measure.width(candidate, prefixed: lead) <= budget)
            }
            lines.append(first..<end)
            first = end
        }
        return lines
    }

    /// The largest end up to `limit` whose range from `first` still holds, found by doubling the step and then halving it.
    private func furthest(from first: Int, to limit: Int, holds: (Range<Int>) -> Bool) -> Int {
        var good = first + 1
        var step = 1
        while good < limit {
            let probe = min(good + step, limit)
            if holds(first..<probe) {
                good = probe
                step *= 2
                continue
            }
            var low = good
            var high = probe
            while high - low > 1 {
                let middle = (low + high) / 2
                if holds(first..<middle) { low = middle } else { high = middle }
            }
            return low
        }
        return good
    }
}
