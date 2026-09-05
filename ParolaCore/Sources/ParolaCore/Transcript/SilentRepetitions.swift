import Foundation

/// How loud the source audio is. The cleanup takes one of these rather than a URL so it stays
/// pure: production hands it a reader over the recording, a test hands it canned levels.
protocol SegmentEnergyProbe {
    /// Loudest half-second of each of the windows the planner spreads over the whole recording.
    func windowEnergies() -> [Double]

    func energy(from start: Double, to end: Double) -> Double?
}

/// Whisper fills silence with a plausible line repeated at VAD-chunk intervals — "Grazie a tutti."
/// four times over a two-minute lead-in. A phrase list cannot tell those from the same words
/// actually spoken, so this asks the audio instead: a line repeated three or more times across the
/// transcript is a candidate, and only the copies whose own span is quiet are dropped.
enum SilentRepetitions {
    static let minimumRepeats = 3

    /// The reference is capped at eight times the median window: one door slam is enough to make
    /// the loudest window several times louder than any speech in the file, and a floor scaled off
    /// that slam alone would sit above the quiet half of a conversation.
    static let medianReferenceFactor = 8.0

    /// It never drops below a tenth of the peak either, or a recording that is mostly digital
    /// silence — median zero — would have no reference at all and nothing would ever be dropped.
    static let minimumReferenceShare = 0.1

    static func dropped(from segments: [TranscriptSegment], probe: SegmentEnergyProbe) -> [TranscriptSegment] {
        var groups: [String: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            let key = normalized(segment.text)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(index)
        }
        let candidates = groups.values
            .filter { $0.count >= minimumRepeats }
            .flatMap { $0 }
            // In playback order, so the energy reads walk the file forward instead of seeking back.
            .sorted { segments[$0].start < segments[$1].start }
        guard !candidates.isEmpty, let floor = floor(forWindows: probe.windowEnergies()) else {
            return segments
        }

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

    /// Below this level a stretch counts as silence. Scaled off the recording's own windows,
    /// because a phone memo and a lapel rig sit decades apart.
    static func floor(forWindows energies: [Double]) -> Double? {
        guard let peak = energies.max(), peak > 0 else { return nil }
        let reference = min(
            peak,
            max(median(of: energies) * medianReferenceFactor, peak * minimumReferenceShare)
        )
        return reference * ProbeWindowPlanner.silenceFloor
    }

    static func normalized(_ text: String) -> String {
        HallucinationPhrases.normalized(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
