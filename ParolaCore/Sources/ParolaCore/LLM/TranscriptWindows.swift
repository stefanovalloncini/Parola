import Foundation

/// Cuts a transcript into consecutive runs of segments that each fit one call to the model.
/// How long a call's answer can run, which decides how much input each window may carry.
public enum AnswerLength: Sendable, Hashable {
    /// A few hundred tokens whatever the input: summaries, chapters, lists.
    case brief
    /// Up to as long as the input: a rewrite hands back what it was given.
    case asLongAsInput
}

enum TranscriptWindows {
    struct Window: Sendable {
        let transcript: Transcript
        let text: String
    }

    /// Where a window sits among the others and how many of the chapters it should mark.
    struct Part: Equatable, Sendable {
        let index: Int
        let count: Int
        let chapters: Int

        /// The longest a part's note can read, so a window is measured with room for it.
        static let widest = Part(index: 99, count: 99, chapters: 99)
    }

    /// The most chapters a transcript gets, however many windows it was read in.
    static let chapterLimit = 10

    /// Each window's share of `chapterLimit`, by the stretch of the recording it covers.
    static func parts(of windows: [Window], in transcript: Transcript) -> [Part] {
        let end = transcript.segments.map(\.end).max() ?? 0
        return windows.indices.map { index in
            let start = index == 0 ? 0 : windows[index].transcript.segments.first?.start ?? 0
            let stop = index + 1 < windows.count ? windows[index + 1].transcript.segments.first?.start ?? end : end
            let share = end > 0 ? (Double(chapterLimit) * (stop - start) / end).rounded() : 1
            return Part(index: index + 1, count: windows.count, chapters: max(1, Int(share)))
        }
    }

    /// `line` is one segment's share of the text, `render` a window's whole text; never returns an empty list.
    static func split(
        _ transcript: Transcript,
        budget: TokenBudget,
        instructions: String,
        answer: AnswerLength = .brief,
        line: (TranscriptSegment) -> String?,
        render: (Transcript) -> String
    ) async -> [Window] {
        let limit = await inputLimit(budget: budget, instructions: instructions, answer: answer)
        let whole = render(transcript)
        if whole.utf8.count <= limit {
            return [Window(transcript: transcript, text: whole)]
        }
        let wholeCount = await budget.count(whole)
        if wholeCount <= limit {
            return [Window(transcript: transcript, text: whole)]
        }
        // Calibrated against the one real count; the 5 % slack absorbs windows denser than the average.
        let scale = Double(wholeCount) / Double(budget.estimate(whole))
        func cost(_ segment: TranscriptSegment) -> Double {
            line(segment).map { Double(budget.estimate($0)) * scale } ?? 0
        }
        let frame = Double(budget.estimate(render(transcript.windowed([])))) * scale
        let lineLimit = max(1, (Double(limit) - frame) * 0.95)

        var runs: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var used = 0.0
        for segment in transcript.segments {
            let segmentCost = cost(segment)
            if !current.isEmpty && used + segmentCost > lineLimit {
                runs.append(current)
                current = []
                used = 0
            }
            current.append(segment)
            used += segmentCost
        }
        if !current.isEmpty { runs.append(current) }

        var windows: [Window] = []
        var carried: [TranscriptSegment] = []
        var next = 0
        while next < runs.count || !carried.isEmpty {
            let run = carried + (next < runs.count ? runs[next] : [])
            next += 1
            let (kept, rest) = await trimmed(run, of: transcript, limit: limit, budget: budget, cost: cost, render: render)
            windows += kept
            carried = rest
        }
        return windows.isEmpty ? [Window(transcript: transcript, text: whole)] : windows
    }

    /// Fits a run by handing its last segments on to the next run, a few tries at most, then by halving.
    private static func trimmed(
        _ run: [TranscriptSegment],
        of transcript: Transcript,
        limit: Int,
        budget: TokenBudget,
        cost: (TranscriptSegment) -> Double,
        render: (Transcript) -> String
    ) async -> (windows: [Window], carried: [TranscriptSegment]) {
        var kept = run
        var carried: [TranscriptSegment] = []
        for _ in 0..<3 {
            let window = transcript.windowed(kept)
            let text = render(window)
            if kept.count == 1 || text.utf8.count <= limit { return ([Window(transcript: window, text: text)], carried) }
            let over = await budget.count(text) - limit
            if over <= 0 { return ([Window(transcript: window, text: text)], carried) }
            var dropped = 0.0
            var moved = 0
            while kept.count > 1, dropped < Double(over) || moved == 0 {
                let last = kept.removeLast()
                dropped += cost(last)
                moved += 1
                carried.insert(last, at: 0)
            }
        }
        return (await fitted(kept, of: transcript, limit: limit, budget: budget, render: render), carried)
    }

    /// Tokens left for a window's text once the instructions and the answer are set aside.
    static func inputLimit(budget: TokenBudget, instructions: String, answer: AnswerLength) async -> Int {
        // Short instructions are prose, which the estimate never undercounts; only a long block is worth asking the model about.
        let fixed = instructions.utf8.count <= 1024 ? budget.estimate(instructions) : await budget.count(instructions)
        var limit = budget.tokens - fixed
        if case .asLongAsInput = answer {
            limit = min(limit, (budget.contextTokens - fixed) / 2, budget.maxAnswerTokens)
        }
        return max(1, limit)
    }

    /// The last resort: halves a run until each half fits; a single segment over the limit goes alone.
    private static func fitted(
        _ run: [TranscriptSegment],
        of transcript: Transcript,
        limit: Int,
        budget: TokenBudget,
        render: (Transcript) -> String
    ) async -> [Window] {
        let window = transcript.windowed(run)
        let text = render(window)
        let fits = await budget.fits(text, within: limit)
        if run.count == 1 || fits {
            return [Window(transcript: window, text: text)]
        }
        let middle = run.count / 2
        let head = await fitted(Array(run[..<middle]), of: transcript, limit: limit, budget: budget, render: render)
        let tail = await fitted(Array(run[middle...]), of: transcript, limit: limit, budget: budget, render: render)
        return head + tail
    }
}

extension Transcript {
    /// A slice of this transcript's segments that keeps its language and model, for one window's prompt.
    func windowed(_ segments: [TranscriptSegment]) -> Transcript {
        Transcript(segments: segments, language: language, modelName: modelName)
    }
}
