import Foundation
@preconcurrency import WhisperKit
@preconcurrency import SpeakerKit

/// Loads SpeakerKit, runs diarization on an audio file, and labels a transcript's segments
/// with speaker IDs. Invoked by ``TranscriptionSession`` when diarization is requested.
actor DiarizationService {
    private var speakerKit: SpeakerKit?

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
            audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
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
        for seg in out.segments {
            let assigned = assignSpeakers(
                to: seg,
                diarization: diarization.segments,
                startingID: &nextID
            )
            rebuilt.append(contentsOf: assigned)
        }
        out.segments = rebuilt
        return out
    }

    static func assignSpeakers(
        to segment: TranscriptSegment,
        diarization: [SpeakerSegment],
        startingID: inout Int
    ) -> [TranscriptSegment] {
        guard let words = segment.words, !words.isEmpty else {
            var copy = segment
            if let speaker = dominantSpeaker(in: diarization, start: segment.start, end: segment.end) {
                copy.speaker = label(for: speaker)
            }
            return [copy]
        }

        var labeledWords: [WordTiming] = []
        labeledWords.reserveCapacity(words.count)
        for word in words {
            var labeled = word
            if let speaker = dominantSpeaker(in: diarization, start: word.start, end: word.end) {
                labeled.speaker = label(for: speaker)
            }
            labeledWords.append(labeled)
        }

        let runs = speakerRuns(in: labeledWords)
        guard runs.count > 1 else {
            var copy = segment
            copy.words = labeledWords
            copy.speaker = labeledWords.first(where: { $0.speaker != nil })?.speaker
                ?? dominantSpeaker(in: diarization, start: segment.start, end: segment.end).map(label(for:))
            return [copy]
        }

        var parts: [TranscriptSegment] = []
        for run in runs {
            let runWords = Array(labeledWords[run.range])
            guard let first = runWords.first, let last = runWords.last else { continue }
            let text = runWords.map(\.word).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let id = parts.isEmpty ? segment.id : startingID
            if !parts.isEmpty { startingID += 1 }
            parts.append(TranscriptSegment(
                id: id,
                start: first.start,
                end: last.end,
                text: text,
                speaker: run.speaker,
                words: runWords
            ))
        }
        return parts.isEmpty ? [segment] : parts
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

    private static func dominantSpeaker(
        in segments: [SpeakerSegment],
        start: Double,
        end: Double
    ) -> SpeakerSegment? {
        var best: SpeakerSegment?
        var bestOverlap: Double = 0
        for s in segments {
            let lo = max(Double(s.startTime), start)
            let hi = min(Double(s.endTime), end)
            let overlap = max(0, hi - lo)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = s
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
