import Foundation

/// How loud a stretch of the source audio is. The cleanup takes one of these rather than a URL so
/// it stays pure: production hands it a reader over the recording, a test hands it canned levels.
protocol SegmentEnergyProbe {
    /// Loudest half-second anywhere in the recording — the reference the silence floor scales from.
    func loudestEnergy() -> Double

    func energy(from start: Double, to end: Double) -> Double?
}

/// Whisper fills silence with a plausible line repeated at VAD-chunk intervals — "Grazie a tutti."
/// four times over a two-minute lead-in. A phrase list cannot tell those from the same words
/// actually spoken, so this asks the audio instead: a line repeated three or more times across the
/// transcript is a candidate, and only the copies whose own span is quiet are dropped.
enum SilentRepetitions {
    static let minimumRepeats = 3

    static func dropped(from segments: [TranscriptSegment], probe: SegmentEnergyProbe) -> [TranscriptSegment] {
        var groups: [String: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            groups[normalized(segment.text), default: []].append(index)
        }
        // Sorted so the energy reads walk the file forward instead of seeking back and forth.
        let candidates = groups.values.filter { $0.count >= minimumRepeats }.flatMap { $0 }.sorted()
        guard !candidates.isEmpty else { return segments }
        let loudest = probe.loudestEnergy()
        guard loudest > 0 else { return segments }

        let floor = loudest * ProbeWindowPlanner.silenceFloor
        var quiet: Set<Int> = []
        for index in candidates {
            let segment = segments[index]
            guard let energy = probe.energy(from: segment.start, to: segment.end), energy < floor else {
                continue
            }
            quiet.insert(index)
        }
        guard !quiet.isEmpty else { return segments }
        ParolaLog.info(
            .engineWhisperKit, "dropped repeated lines that sit on silence",
            [.count: .int(quiet.count)]
        )
        return segments.enumerated().filter { !quiet.contains($0.offset) }.map(\.element)
    }

    static func normalized(_ text: String) -> String {
        HallucinationPhrases.normalized(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}
