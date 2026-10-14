import Foundation

/// A caption cue: the lines on screen and when. A cue pairing two languages holds one line of each, or two of each when the time is short.
struct CaptionCue: Equatable {
    var start: Double
    var end: Double
    var lines: [String]
    var translation: [String]
    /// The visible speaker label, on the first cue of a segment only.
    var speaker: String?
    /// The speaker of the segment, on every one of its cues, for formats that carry it as metadata.
    var voice: String?
    let source: Int
    var tag: Int = 0

    func shownLines(speakerPrefix: (String) -> String) -> [String] {
        let labelled = speaker.map { [speakerPrefix($0) + (lines.first ?? "")] + lines.dropFirst() } ?? lines
        return labelled + translation
    }
}

/// A speaker's run of segments; each part is split and timed against its own span.
struct CaptionCueSource {
    struct Part {
        var text: String
        var start: Double
        var end: Double
        var words: [WordTiming]?
        var translation: String?
        var language: String?
        var translationLanguage: String?

        init(
            text: String, start: Double, end: Double, words: [WordTiming]? = nil, translation: String? = nil,
            language: String? = nil, translationLanguage: String? = nil
        ) {
            self.text = text
            self.start = start
            self.end = end
            self.words = words
            self.translation = translation
            self.language = language
            self.translationLanguage = translationLanguage
        }
    }

    var parts: [Part]
    var speaker: String?
    var tag = 0
}

enum CaptionCues {
    /// A cue is held at least this long: one second is what a viewer needs to read a word or two.
    static let minCueSeconds = 1.0
    /// A gap this short between two cues of one segment is closed, so the caption does not flicker.
    static let closedGapSeconds = 1.0
    /// A pause this long inside a segment starts a new cue, so a cue does not stay up through the silence.
    static let silenceBreakSeconds = 1.0
    static let maxLinesPerCue = 2

    /// The sources a transcript's captions are cut from: segments grouped as the spec asks, or one source per segment.
    static func sources(from transcript: Transcript, spec: ExportSpec, grouped: Bool = true) -> [CaptionCueSource] {
        var ungrouped = spec
        ungrouped.options.grouping = .none
        return sources(prepared: ungrouped.prepared(transcript), spec: spec, grouped: grouped)
    }

    /// Sources from a transcript the spec has already prepared; a merged segment is one part, timed over its whole span.
    static func sources(prepared: Transcript, spec: ExportSpec, grouped: Bool) -> [CaptionCueSource] {
        let both = spec.resolvedContent == .both
        let translated = spec.resolvedContent == .translation
        let runs = grouped ? spec.options.grouping.runs(of: prepared.segments) : prepared.segments.map { [$0] }
        let language = translated ? prepared.translation?.targetLanguage ?? prepared.language : prepared.language
        return runs.compactMap { run in
            let parts = run.compactMap { segment -> CaptionCueSource.Part? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let translation = both
                    ? prepared.translation?.segments[segment.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil
                return CaptionCueSource.Part(
                    text: text, start: segment.start, end: segment.end, words: segment.words,
                    translation: translation.flatMap { $0.isEmpty ? nil : $0 },
                    language: language, translationLanguage: prepared.translation?.targetLanguage
                )
            }
            guard !parts.isEmpty else { return nil }
            let speaker = spec.options.speakers ? Format.presentationSpeakerLabel(run[0].speaker) : nil
            return CaptionCueSource(parts: parts, speaker: speaker)
        }
    }

    /// Lines a renderer can check once they are final, and what to pack a segment with when one does not fit.
    struct Verification {
        let fits: (String) -> Bool
        let fallback: CaptionBreaker
    }

    /// The cues a file or the burn shows: split, timed to the speech, then made readable alongside their neighbours.
    static func cues(
        for sources: [CaptionCueSource], breaker: CaptionBreaker, speakerPrefix: (String) -> String,
        verifying: Verification? = nil
    ) throws -> [CaptionCue] {
        settle(try packed(sources, breaker: breaker, speakerPrefix: speakerPrefix, verifying: verifying))
    }

    /// Cues as split and timed from the speech, before the pass that fits them in beside the cues around them.
    static func packed(
        _ sources: [CaptionCueSource], breaker: CaptionBreaker, speakerPrefix: (String) -> String,
        verifying: Verification? = nil
    ) throws -> [CaptionCue] {
        let tokenizer = CaptionTokenizer()
        var cues: [CaptionCue] = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            var label = source.speaker
            for part in source.parts {
                let prefix = label.map(speakerPrefix) ?? ""
                func make(_ breaker: CaptionBreaker) -> [CaptionCue] {
                    var made = partCues(part, prefix: prefix, breaker: breaker, tokenizer: tokenizer, source: index)
                    if !made.isEmpty { made[0].speaker = label }
                    return made
                }
                var made = make(breaker)
                if let verifying, !made.allSatisfy({ $0.shownLines(speakerPrefix: speakerPrefix).allSatisfy(verifying.fits) }) {
                    made = make(verifying.fallback)
                }
                guard !made.isEmpty else { continue }
                label = nil
                for cue in made.indices {
                    made[cue].voice = source.speaker
                    made[cue].tag = source.tag
                }
                cues += made
            }
        }
        return cues
    }

    // MARK: - One segment

    private struct Chunk {
        var original: Range<Int>?
        var translated: Range<Int>?
        var originalLines: [String] = []
        var translatedLines: [String] = []
    }

    private static func partCues(
        _ part: CaptionCueSource.Part, prefix: String, breaker: CaptionBreaker, tokenizer: CaptionTokenizer, source: Int
    ) -> [CaptionCue] {
        let start = max(part.start, 0)
        let end = max(part.end, start)
        let cap = max(1, Int((end - start) / minCueSeconds + 1e-9))

        let original = Side(text: part.text, language: part.language, prefix: prefix, breaker: breaker, tokenizer: tokenizer)
        guard !original.atoms.isEmpty else { return [] }
        let translated = part.translation.map {
            Side(text: $0, language: part.translationLanguage, prefix: "", breaker: breaker, tokenizer: tokenizer)
        }.flatMap { $0.atoms.isEmpty ? nil : $0 }

        let clock = WordClock(words: part.words, text: part.text, within: start...end)
        let chunks = translated.map { pairs(original, $0, cap: cap) } ?? single(original, clock: clock, cap: cap)
        let weights = chunks.enumerated().map { index, chunk in
            Double(original.weight(chunk.original) + (translated?.weight(chunk.translated) ?? 0) + (index == 0 ? prefix.count : 0))
        }
        let timed = clock != nil && chunks.allSatisfy { $0.original != nil }
        let spans = timed
            ? wordSpans(chunks.compactMap(\.original), atoms: original.atoms, clock: clock!, within: start...end)
            : nil
        let shared = proportional(weights, within: start...end)
        let settled = spans ?? enforceMinimum(shared, within: start...end) ?? shared
        return zip(chunks, settled).map { chunk, span in
            CaptionCue(
                start: span.0, end: span.1, lines: chunk.originalLines, translation: chunk.translatedLines,
                speaker: nil, voice: nil, source: source
            )
        }
    }

    /// One language's atoms and how to measure them.
    private struct Side {
        let atoms: [CaptionAtom]
        let packer: CaptionPacker

        init(text: String, language: String?, prefix: String, breaker: CaptionBreaker, tokenizer: CaptionTokenizer) {
            var atoms = CaptionAtom.atoms(in: text, language: language, tokenizer: tokenizer)
            var measure = breaker.measure(atoms, prefix)
            for _ in 0..<2 {
                let tooWide = Set(atoms.indices.filter { !measure.fits($0..<($0 + 1), prefixed: false) && atoms[$0].hasUnspacedScript })
                if tooWide.isEmpty { break }
                atoms = atoms.enumerated().flatMap { tooWide.contains($0.offset) ? $0.element.exploded() : [$0.element] }
                measure = breaker.measure(atoms, prefix)
            }
            self.atoms = atoms
            packer = CaptionPacker(atoms: atoms, measure: measure)
        }

        func weight(_ range: Range<Int>?) -> Int {
            guard let range else { return 0 }
            return atoms[range].reduce(0) { $0 + $1.text.count + ($1.spaceBefore ? 1 : 0) }
        }

        var all: Range<Int> { 0..<atoms.count }
    }

    private static func single(_ side: Side, clock: WordClock?, cap: Int) -> [Chunk] {
        let silences = clock?.silenceOffsets(atLeast: silenceBreakSeconds) ?? []
        let breaks = side.atoms.indices.filter { silences.contains(side.atoms[$0].offset) }
        var groups = side.packer.groups(prefixed: true, maxLines: maxLinesPerCue, breaks: breaks)
        if groups.count > cap { groups = side.packer.groups(prefixed: true, maxLines: maxLinesPerCue) }
        guard groups.count <= cap else {
            return [Chunk(original: side.all, originalLines: side.packer.wrapped(side.all, prefixed: true))]
        }
        return groups.enumerated().map { index, group in
            Chunk(original: group, originalLines: side.packer.lines(group, prefixed: index == 0, maxLines: maxLinesPerCue))
        }
    }

    /// Both languages in reading order: chunk i of each shares cue i, and a language that runs out leaves the rest to the other, two lines a cue.
    private static func pairs(_ original: Side, _ translated: Side, cap: Int) -> [Chunk] {
        for lines in [1, maxLinesPerCue] {
            let chunks = paired(original, translated, lines: lines)
            if chunks.count <= cap { return chunks }
        }
        return [Chunk(
            original: original.all, translated: translated.all,
            originalLines: original.packer.wrapped(original.all, prefixed: true),
            translatedLines: translated.packer.wrapped(translated.all, prefixed: false)
        )]
    }

    private static func paired(_ original: Side, _ translated: Side, lines: Int) -> [Chunk] {
        let originalGroups = original.packer.groups(prefixed: true, maxLines: lines)
        let translatedGroups = translated.packer.groups(prefixed: false, maxLines: lines)
        let together = min(originalGroups.count, translatedGroups.count)
        var chunks = (0..<together).map { index in
            Chunk(
                original: originalGroups[index], translated: translatedGroups[index],
                originalLines: original.packer.lines(originalGroups[index], prefixed: index == 0, maxLines: lines),
                translatedLines: translated.packer.lines(translatedGroups[index], prefixed: false, maxLines: lines)
            )
        }
        if originalGroups.count > together {
            let rest = originalGroups[together].lowerBound..<original.atoms.count
            chunks += original.packer.groups(in: rest, prefixed: false, maxLines: maxLinesPerCue).map {
                Chunk(original: $0, originalLines: original.packer.lines($0, prefixed: false, maxLines: maxLinesPerCue))
            }
        }
        if translatedGroups.count > together {
            let rest = translatedGroups[together].lowerBound..<translated.atoms.count
            chunks += translated.packer.groups(in: rest, prefixed: false, maxLines: maxLinesPerCue).map {
                Chunk(translated: $0, translatedLines: translated.packer.lines($0, prefixed: false, maxLines: maxLinesPerCue))
            }
        }
        return chunks
    }

    // MARK: - Timing

    private static func proportional(_ weights: [Double], within span: ClosedRange<Double>) -> [(Double, Double)] {
        let total = max(weights.reduce(0, +), 1)
        var spent = 0.0
        return weights.map { weight in
            defer { spent += weight }
            return (span.lowerBound + (span.upperBound - span.lowerBound) * spent / total,
                    span.lowerBound + (span.upperBound - span.lowerBound) * (spent + weight) / total)
        }
    }

    /// Each group's first word to its last, kept a cue's minimum long where the speech allows; nil when it can't be, so the caller shares time by characters.
    private static func wordSpans(
        _ groups: [Range<Int>], atoms: [CaptionAtom], clock: WordClock, within span: ClosedRange<Double>
    ) -> [(Double, Double)]? {
        let spans = groups.map { group -> (Double, Double) in
            let last = atoms[group.upperBound - 1]
            let start = min(max(clock.start(atOffset: atoms[group.lowerBound].offset), span.lowerBound), span.upperBound)
            let end = min(max(clock.end(atOffset: last.offset + last.text.count), start), span.upperBound)
            return (start, end)
        }
        return enforceMinimum(spans, within: span)
    }

    /// Lengthens cues shorter than the minimum by moving the cuts between neighbours, or into the silence on either side; nil when there is no room.
    private static func enforceMinimum(_ spans: [(Double, Double)], within span: ClosedRange<Double>) -> [(Double, Double)]? {
        guard spans.count > 1 else { return spans }
        var times = spans
        var chains: [Range<Int>] = []
        var from = 0
        for index in 0..<(times.count - 1) {
            if times[index + 1].0 - times[index].1 < closedGapSeconds {
                times[index].1 = max(times[index].1, times[index + 1].0)
                times[index + 1].0 = times[index].1
            } else {
                chains.append(from..<(index + 1))
                from = index + 1
            }
        }
        chains.append(from..<times.count)

        for (position, chain) in chains.enumerated() {
            let count = chain.count
            var low = times[chain.lowerBound].0
            var high = times[chain.upperBound - 1].1
            let needed = Double(count) * minCueSeconds
            if high - low < needed - 1e-9 {
                let ceiling = position + 1 < chains.count ? times[chains[position + 1].lowerBound].0 : span.upperBound
                high = min(low + needed, max(ceiling, high))
                if high - low < needed - 1e-9 {
                    let floor = position > 0 ? times[chains[position - 1].upperBound - 1].1 : span.lowerBound
                    low = max(min(floor, low), high - needed)
                }
                if high - low < needed - 1e-9 { return nil }
            }
            var cuts = [low] + chain.dropLast().map { times[$0].1 } + [high]
            for index in 1..<count { cuts[index] = max(cuts[index], cuts[index - 1] + minCueSeconds) }
            for index in stride(from: count - 1, through: 1, by: -1) { cuts[index] = min(cuts[index], cuts[index + 1] - minCueSeconds) }
            for (offset, index) in chain.enumerated() { times[index] = (cuts[offset], cuts[offset + 1]) }
        }
        return times
    }

    // MARK: - Beside the neighbours

    /// Orders the cues, closes short gaps inside a segment, trims a cue where the next segment starts, and holds each cue to its minimum, short of the next cue and of any cue it sits inside.
    static func settle(_ cues: [CaptionCue]) -> [CaptionCue] {
        var cues = cues.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)

        var latest: [Int: Int] = [:]
        for index in cues.indices {
            if let before = latest[cues[index].source] {
                let gap = cues[index].start - cues[before].end
                if gap > 0, gap < closedGapSeconds { cues[before].end = cues[index].start }
            }
            latest[cues[index].source] = index
        }

        for index in cues.indices {
            var next = index + 1
            while next < cues.count, cues[next].start < cues[index].end {
                let overlaps = cues[next].end > cues[index].end && cues[next].source != cues[index].source
                if overlaps, cues[next].start - cues[index].start >= minCueSeconds {
                    cues[index].end = cues[next].start
                    break
                }
                next += 1
            }
        }

        var nextStarts = [Double](repeating: .infinity, count: cues.count)
        var upcoming = Double.infinity
        for index in cues.indices.reversed() {
            if index + 1 < cues.count, cues[index + 1].start > cues[index].start { upcoming = cues[index + 1].start }
            nextStarts[index] = upcoming
        }
        var open: [Int] = []
        for index in cues.indices {
            open.removeAll { cues[$0].end <= cues[index].start }
            let natural = cues[index].end
            var ceiling = min(cues[index].start + minCueSeconds, nextStarts[index])
            for outer in open where cues[outer].source != cues[index].source && cues[outer].end >= natural {
                ceiling = min(ceiling, cues[outer].end)
            }
            cues[index].end = max(natural, ceiling, cues[index].start + Format.minCaptionSeconds)
            open.append(index)
        }
        return cues
    }
}

/// Maps a position in a segment's spoken characters to a time, when its word timings say exactly the segment's text.
struct WordClock {
    private struct Entry {
        let lower: Int
        let upper: Int
        let start: Double
        let end: Double
    }

    private let entries: [Entry]

    init?(words: [WordTiming]?, text: String, within span: ClosedRange<Double>) {
        guard let words else { return nil }
        let slack = 1.0
        var entries: [Entry] = []
        var spoken = ""
        var count = 0
        for word in words {
            let piece = word.word.filter { !$0.isWhitespace }
            guard !piece.isEmpty else { continue }
            guard word.end >= word.start, entries.last.map({ word.start >= $0.start }) ?? true,
                  word.start >= span.lowerBound - slack, word.end <= span.upperBound + slack else { return nil }
            entries.append(Entry(lower: count, upper: count + piece.count, start: word.start, end: word.end))
            spoken += piece
            count += piece.count
        }
        guard !entries.isEmpty, spoken == text.filter({ !$0.isWhitespace }) else { return nil }
        self.entries = entries
    }

    /// Where, in spoken characters, a pause of at least `seconds` falls between two words.
    func silenceOffsets(atLeast seconds: Double) -> [Int] {
        zip(entries, entries.dropFirst()).filter { $1.start - $0.end >= seconds }.map { $1.lower }
    }

    func start(atOffset offset: Int) -> Double {
        let entry = entries.first { offset < $0.upper } ?? entries[entries.count - 1]
        return time(in: entry, at: offset)
    }

    func end(atOffset offset: Int) -> Double {
        let entry = entries.first { offset <= $0.upper } ?? entries[entries.count - 1]
        return time(in: entry, at: offset)
    }

    private func time(in entry: Entry, at offset: Int) -> Double {
        let share = Double(min(max(offset - entry.lower, 0), entry.upper - entry.lower)) / Double(entry.upper - entry.lower)
        return entry.start + (entry.end - entry.start) * share
    }
}
