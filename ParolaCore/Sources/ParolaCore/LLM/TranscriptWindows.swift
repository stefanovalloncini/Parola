import Foundation

/// Cuts a transcript into consecutive runs of segments that each fit one call to the model.
enum TranscriptWindows {
    enum Answer: Sendable {
        /// A few hundred tokens whatever the input: summaries, chapters, lists.
        case brief
        /// Up to as long as the input: a rewrite hands back what it was given.
        case asLongAsInput
    }

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
        answer: Answer = .brief,
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
        // Calibrated against the one real count so windows come out near full; each is still checked below.
        let scale = Double(wholeCount) / Double(budget.estimate(whole))
        let frame = Double(budget.estimate(render(transcript.windowed([])))) * scale
        let lineLimit = max(1, Double(limit) - frame)

        var runs: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var used = 0.0
        for segment in transcript.segments {
            let cost = line(segment).map { Double(budget.estimate($0)) * scale } ?? 0
            if !current.isEmpty && used + cost > lineLimit {
                runs.append(current)
                current = []
                used = 0
            }
            current.append(segment)
            used += cost
        }
        if !current.isEmpty { runs.append(current) }

        var windows: [Window] = []
        for run in runs {
            windows += await fitted(run, of: transcript, limit: limit, budget: budget, render: render)
        }
        return windows.isEmpty ? [Window(transcript: transcript, text: whole)] : windows
    }

    /// Tokens left for a window's text once the instructions and the answer are set aside.
    static func inputLimit(budget: TokenBudget, instructions: String, answer: Answer) async -> Int {
        // Short instructions are prose, which the estimate never undercounts; only a long block is worth asking the model about.
        let fixed = instructions.utf8.count <= 1024 ? budget.estimate(instructions) : await budget.count(instructions)
        var limit = budget.tokens - fixed
        if case .asLongAsInput = answer {
            limit = min(limit, (budget.contextTokens - fixed) / 2)
        }
        return max(1, limit)
    }

    /// Halves a run until each half fits; a single segment over the limit goes alone.
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
