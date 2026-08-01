import Foundation
@preconcurrency import WhisperKit
@preconcurrency import SpeakerKit

/// Loads SpeakerKit, runs diarization on an audio file, and labels a transcript's segments
/// with speaker IDs. Invoked by ``TranscriptionSession`` when diarization is requested.
actor DiarizationService {
    private var speakerKit: SpeakerKit?
    private(set) var unloadCount = 0

    init() {}

    func diarize(
        transcript: Transcript,
        audioURL: URL,
        numberOfSpeakers: Int? = nil
    ) async throws -> Transcript {
        guard !transcript.segments.isEmpty else { return transcript }

        if speakerKit == nil {
            do {
                speakerKit = try await SpeakerKit(PyannoteConfig())
            } catch {
                throw ParolaError.transcriptionFailed("SpeakerKit init failed: \(error.localizedDescription)")
            }
        }
        guard let kit = speakerKit else {
            throw ParolaError.transcriptionFailed("SpeakerKit unavailable")
        }

        let audioArray: [Float]
        do {
            // Detached: the synchronous decode would otherwise pin a cooperative-pool thread for the whole file.
            let path = audioURL.path
            audioArray = try await Task.detached(priority: .userInitiated) {
                try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            }.value
        } catch {
            throw ParolaError.audioLoadFailed(audioURL, underlying: error.localizedDescription)
        }

        let result: DiarizationResult
        do {
            result = try await kit.diarize(
                audioArray: audioArray,
                options: PyannoteDiarizationOptions(numberOfSpeakers: numberOfSpeakers)
            )
        } catch {
            throw ParolaError.transcriptionFailed("Diarization failed: \(error.localizedDescription)")
        }

        return Self.merge(transcript: transcript, diarization: result)
    }

    func unload() async {
        unloadCount += 1
        await speakerKit?.unloadModels()
        speakerKit = nil
    }

    /// Maps SpeakerKit's labeled segments back onto our `Transcript`. Each transcript segment
    /// gets the dominant speaker by overlap. When word timings are present, each word also
    /// gets its own speaker label and segments are split on speaker boundaries.
    static func merge(transcript: Transcript, diarization: DiarizationResult) -> Transcript {
        var out = transcript
        var rebuilt: [TranscriptSegment] = []
        rebuilt.reserveCapacity(out.segments.count)
        var nextID = (out.segments.map(\.id).max() ?? -1) + 1
        let intervals = SpeakerIntervals(diarization.segments)
        for seg in out.segments {
            let assigned = assignSpeakers(
                to: seg,
                diarization: intervals,
                startingID: &nextID
            )
            rebuilt.append(contentsOf: assigned)
        }
        out.segments = rebuilt
        return out
    }

    static func assignSpeakers(
        to segment: TranscriptSegment,
        diarization: SpeakerIntervals,
        startingID: inout Int
    ) -> [TranscriptSegment] {
        guard let words = segment.words, !words.isEmpty else {
            var copy = segment
            if let speaker = diarization.dominantSpeaker(start: segment.start, end: segment.end) {
                copy.speaker = label(for: speaker)
            }
            return [copy]
        }

        var labeledWords: [WordTiming] = []
        labeledWords.reserveCapacity(words.count)
        for word in words {
            var labeled = word
            if let speaker = diarization.dominantSpeaker(start: word.start, end: word.end) {
                labeled.speaker = label(for: speaker)
            }
            labeledWords.append(labeled)
        }

        let runs = speakerRuns(in: labeledWords)
        guard runs.count > 1 else {
            var copy = segment
            copy.words = labeledWords
            copy.speaker = labeledWords.first(where: { $0.speaker != nil })?.speaker
                ?? diarization.dominantSpeaker(start: segment.start, end: segment.end).map(label(for:))
            return [copy]
        }

        var parts: [TranscriptSegment] = []
        for run in runs {
            let runWords = Array(labeledWords[run.range])
            guard let first = runWords.first, let last = runWords.last else { continue }
            let text = Self.joinWordTexts(runWords.map(\.word)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let id = parts.isEmpty ? segment.id : startingID
            if !parts.isEmpty { startingID += 1 }
            let renumbered = runWords.enumerated().map { index, word -> WordTiming in
                var word = word
                word.id = "\(id)-\(index)"
                return word
            }
            parts.append(TranscriptSegment(
                id: id,
                start: first.start,
                end: last.end,
                text: text,
                speaker: run.speaker,
                words: renumbered
            ))
        }
        return parts.isEmpty ? [segment] : parts
    }

    /// Space-joins word tokens but keeps a leading-apostrophe elision tail attached: WhisperKit splits "l'altro" into ["l", "'altro"], which a plain join would space out to "l 'altro".
    static func joinWordTexts(_ words: [String]) -> String {
        var text = ""
        for word in words {
            if text.isEmpty || word.first == "'" || word.first == "\u{2019}" {
                text += word
            } else {
                text += " " + word
            }
        }
        return text
    }

    private struct SpeakerRun {
        let speaker: String?
        let range: Range<Int>
    }

    private static func speakerRuns(in words: [WordTiming]) -> [SpeakerRun] {
        var runs: [SpeakerRun] = []
        var start = 0
        var currentSpeaker = words.first?.speaker
        for i in 1..<words.count {
            if words[i].speaker != currentSpeaker {
                runs.append(SpeakerRun(speaker: currentSpeaker, range: start..<i))
                start = i
                currentSpeaker = words[i].speaker
            }
        }
        runs.append(SpeakerRun(speaker: currentSpeaker, range: start..<words.count))
        return runs
    }

    /// The diarizer's intervals, prepared once per merge. SpeakerKit sorts them by start time but
    /// lets them overlap across speakers, so a running maximum of the end times is what makes a
    /// lookup a binary search plus a short forward scan. Unsorted input falls back to a linear scan.
    struct SpeakerIntervals {
        private let segments: [SpeakerSegment]
        private let bounds: [(start: Double, end: Double)]
        private let maxEnd: [Double]
        private let sortedByStart: Bool

        init(_ segments: [SpeakerSegment]) {
            let bounds = segments.map { (start: Double($0.startTime), end: Double($0.endTime)) }
            var running: [Double] = []
            running.reserveCapacity(bounds.count)
            var highest = -Double.infinity
            for interval in bounds {
                highest = max(highest, interval.end)
                running.append(highest)
            }
            self.segments = segments
            self.bounds = bounds
            self.maxEnd = running
            self.sortedByStart = zip(bounds, bounds.dropFirst()).allSatisfy { $0.start <= $1.start }
        }

        func dominantSpeaker(start: Double, end: Double) -> SpeakerSegment? {
            matchIndex(start: start, end: end).map { segments[$0] }
        }

        func matchIndex(start: Double, end: Double) -> Int? {
            guard sortedByStart else {
                return DiarizationService.bestMatchIndex(start: start, end: end, intervals: bounds)
            }
            if end <= start {
                let i = firstIndex(whereMaxEnd: { $0 >= start })
                guard i < bounds.count, bounds[i].start <= start else { return nil }
                return i
            }
            var best: Int?
            var bestOverlap: Double = 0
            var i = firstIndex(whereMaxEnd: { $0 > start })
            while i < bounds.count, bounds[i].start < end {
                let overlap = min(bounds[i].end, end) - max(bounds[i].start, start)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    best = i
                }
                i += 1
            }
            return best
        }

        private func firstIndex(whereMaxEnd reaches: (Double) -> Bool) -> Int {
            var low = 0
            var high = maxEnd.count
            while low < high {
                let mid = low + (high - low) / 2
                if reaches(maxEnd[mid]) { high = mid } else { low = mid + 1 }
            }
            return low
        }
    }

    /// Index of the interval that best matches `[start, end]` by overlap. A zero-duration query
    /// (start == end, e.g. a punctuation token) has no overlap to measure, so it falls back to the
    /// first interval that contains the point — otherwise such a word stays unlabeled and fragments
    /// a single-speaker segment into a nil island.
    static func bestMatchIndex(start: Double, end: Double, intervals: [(start: Double, end: Double)]) -> Int? {
        if end <= start {
            return intervals.firstIndex { $0.start <= start && start <= $0.end }
        }
        var best: Int?
        var bestOverlap: Double = 0
        for (i, iv) in intervals.enumerated() {
            let overlap = max(0, min(iv.end, end) - max(iv.start, start))
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = i
            }
        }
        return bestOverlap > 0 ? best : nil
    }

    private static func label(for segment: SpeakerSegment) -> String {
        if let id = segment.speaker.speakerId {
            return "Speaker \(id + 1)"
        }
        return "Unknown"
    }
}
