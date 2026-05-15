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
        guard transcript.segments.contains(where: { ($0.words?.isEmpty == false) }) else {
            return transcript
        }

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

    /// Maps SpeakerKit's labeled segments back onto our `Transcript`. Each transcript
    /// segment gets the dominant speaker by overlap; word timings get per-word speakers.
    static func merge(transcript: Transcript, diarization: DiarizationResult) -> Transcript {
        var out = transcript
        for i in out.segments.indices {
            var seg = out.segments[i]
            guard let speaker = dominantSpeaker(in: diarization.segments, start: seg.start, end: seg.end) else {
                out.segments[i] = seg
                continue
            }
            seg.speaker = label(for: speaker)

            out.segments[i] = seg
        }
        return out
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
