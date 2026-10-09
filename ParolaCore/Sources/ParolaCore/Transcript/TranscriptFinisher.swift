import Foundation

/// The steps every finished transcript goes through, whether it came from a file run or a live take.
enum TranscriptFinisher {
    static func finish(
        _ transcript: Transcript,
        engine: EngineID,
        options: TranscriptionOptions,
        audioURL: URL?,
        readDeadline: Duration = FileReadDeadline.header
    ) async -> Transcript {
        let tidied = await tidied(
            transcript, engine: engine, options: options, audioURL: audioURL,
            windowEnergies: nil, readDeadline: readDeadline, readClock: ContinuousClock()
        )
        return merged(tidied, engine: engine)
    }

    /// `labelSpeakers` runs before the merge so the merger's speaker guard sees the labels.
    static func finish(
        _ transcript: Transcript,
        engine: EngineID,
        options: TranscriptionOptions,
        audioURL: URL?,
        windowEnergies: [Double]? = nil,
        readDeadline: Duration = FileReadDeadline.header,
        readClock: any Clock<Duration> = ContinuousClock(),
        labelSpeakers: @Sendable (Transcript) async throws -> Transcript
    ) async throws -> Transcript {
        let tidied = await tidied(
            transcript, engine: engine, options: options, audioURL: audioURL,
            windowEnergies: windowEnergies, readDeadline: readDeadline, readClock: readClock
        )
        return merged(try await labelSpeakers(tidied), engine: engine)
    }

    /// A prompted run over silence comes back with the prompt itself as its only segment, and
    /// nothing downstream catches it: WhisperKit's no-speech probability is hard-coded to zero.
    static func droppingPromptEcho(_ segments: [TranscriptSegment], prompt: String?) -> [TranscriptSegment] {
        guard let prompt, segments.count == 1 else { return segments }
        return IgnoredSegments.apply(rules: [IgnoredSegmentRule(pattern: prompt)], to: segments)
    }

    private static func tidied(
        _ transcript: Transcript,
        engine: EngineID,
        options: TranscriptionOptions,
        audioURL: URL?,
        windowEnergies: [Double]?,
        readDeadline: Duration,
        readClock: any Clock<Duration>
    ) async -> Transcript {
        let cleanup = TranscriptCleanupOptions(
            filtersHallucinations: options.filtersHallucinations,
            mergesSentences: false
        )
        guard engine == .whisperKit else {
            return TranscriptCleanup.apply(to: transcript, options: cleanup, energy: nil)
        }
        var transcript = transcript
        let kept = droppingPromptEcho(transcript.segments, prompt: options.initialPrompt)
        if kept.count != transcript.segments.count {
            ParolaLog.info(
                .engineWhisperKit, "dropped a transcript that was only the prompt read back",
                [.model: .safe(ModelToken(transcript.modelName))]
            )
            transcript.segments = kept
        }
        var cleaned = await cleanedWithEnergy(
            transcript, at: audioURL, windowEnergies: windowEnergies,
            options: cleanup, deadline: readDeadline, clock: readClock
        )
        // After the energy pass: clamped spans would point its reads at the engine's padding.
        cleaned.segments = PaddedSegmentSpan.clamped(cleaned.segments)
        return cleaned
    }

    /// Unbounded, a parked read here would hold whatever called the finish.
    private static func cleanedWithEnergy(
        _ transcript: Transcript,
        at audioURL: URL?,
        windowEnergies: [Double]?,
        options: TranscriptCleanupOptions,
        deadline: Duration,
        clock: any Clock<Duration>
    ) async -> Transcript {
        guard let audioURL else {
            return TranscriptCleanup.apply(to: transcript, options: options, energy: nil)
        }
        let read = await BoundedFileRead.run(deadline: deadline, clock: clock) {
            TranscriptCleanup.apply(
                to: transcript,
                options: options,
                energy: AudioFileEnergyProbe(url: audioURL, windowEnergies: windowEnergies)
            )
        }
        guard case .done(let cleaned) = read else {
            ParolaLog.notice(.models, "skipped the energy pass: the file stopped reading")
            return TranscriptCleanup.apply(to: transcript, options: options, energy: nil)
        }
        return cleaned
    }

    private static func merged(_ transcript: Transcript, engine: EngineID) -> Transcript {
        TranscriptCleanup.apply(
            to: transcript,
            options: TranscriptCleanupOptions(
                filtersHallucinations: false,
                mergesSentences: engine == .whisperKit
            )
        )
    }
}
