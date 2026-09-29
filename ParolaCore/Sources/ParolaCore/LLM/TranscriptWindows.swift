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
        let fixed = instructions.isEmpty ? 0 : await budget.count(instructions)
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
