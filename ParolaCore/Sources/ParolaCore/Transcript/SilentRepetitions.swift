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
/// actually spoken, so this asks the audio and the layout instead: a line repeated three or more
/// times is a candidate, and a copy goes only when its span is quiet AND another copy sits right
/// beside it. Filler arrives back to back; a line the other speaker talks around does not.
enum SilentRepetitions {
    static let minimumRepeats = 3

    /// A window holding at least a tenth of the peak is one the planner would call speech
    /// (`ProbeWindowPlanner.pick`); the middle of that set is what a spoken line measures there.
    static let loudWindowShare = ProbeWindowPlanner.silenceFloor
    static let minimumLoudWindows = 3

    /// Silence is four tenths of that. Three measured tables pin the share:
    /// the 159 memo gives 0.0157 — over its loudest hallucination (0.0124), 4.2× under its speech;
    /// uniform speech at 0.02 with one 0.15 thump gives 0.008, so speech-level repeats stay;
    /// 16 windows of room tone against 8 at 0.08 give 0.032, so a 0.005 repeat over silence goes.
    /// The memo's loudest filler and a speaker 10 dB down measure the same, so what separates them
    /// is the neighbour test, not this.
    static let quietShareOfSpeech = 0.4

    /// Below three loud windows there is no middle to take. The fallback is the whole-file median,
    /// capped so one transient cannot set the level alone and floored so a recording that is
    /// almost all digital silence still has a reference to scale from.
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
