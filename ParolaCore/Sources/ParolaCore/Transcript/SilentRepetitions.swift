import Foundation

/// How loud the source audio is, kept abstract so production and tests can both supply it.
protocol SegmentEnergyProbe {
    /// Loudest half-second of each of the windows the planner spreads over the whole recording.
    func windowEnergies() -> [Double]

    func energy(from start: Double, to end: Double) -> Double?
}

/// Drops a repeated line only when its span is quiet and another copy sits right beside it — filler
/// arrives back to back, a line the other speaker talks around does not.
enum SilentRepetitions {
    static let minimumRepeats = 3

    /// A window at or above this share of the peak reads as speech (`ProbeWindowPlanner.pick`).
    static let loudWindowShare = ProbeWindowPlanner.silenceFloor
    static let minimumLoudWindows = 3

    /// 0.4× the loud-window level; measured admissible band across three fixtures is 0.008–0.032.
    static let quietShareOfSpeech = 0.4

    /// Median-fallback bounds when fewer than three loud windows exist: capped 8×, floored at 10%.
    static let medianReferenceFactor = 8.0
    static let minimumReferenceShare = 0.1

    static func dropped(from segments: [TranscriptSegment], probe: SegmentEnergyProbe) -> [TranscriptSegment] {
        var groups: [String: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            let key = normalized(segment.text)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(index)
        }
        let repeated = Set(groups.values.filter { $0.count >= minimumRepeats }.flatMap { $0 })
        guard !repeated.isEmpty, let floor = floor(forWindows: probe.windowEnergies()) else {
            return segments
        }

        // Walked in playback order: the energy reads go forward through the file, and a copy's
        // neighbours are the segments either side of it in time.
        let order = segments.indices.sorted { segments[$0].start < segments[$1].start }
        var quiet: Set<Int> = []
        for (position, index) in order.enumerated() where repeated.contains(index) {
            let before = position > 0 && repeated.contains(order[position - 1])
            let after = position + 1 < order.count && repeated.contains(order[position + 1])
            guard before || after else { continue }
            let segment = segments[index]
            guard let energy = probe.energy(from: segment.start, to: segment.end), energy < floor else {
                continue
            }
            quiet.insert(index)
            ParolaLog.debug(
                .engineWhisperKit, "dropping a repeated line over silence",
                [.offset: .seconds(segment.start), .energy: .double(energy), .floor: .double(floor)]
            )
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
        let loud = energies.filter { $0 >= peak * loudWindowShare }
        guard loud.count >= minimumLoudWindows else {
            let reference = min(
                peak,
                max(median(of: energies) * medianReferenceFactor, peak * minimumReferenceShare)
            )
            return reference * ProbeWindowPlanner.silenceFloor
        }
        return median(of: loud) * quietShareOfSpeech
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
