import AVFoundation
import Foundation

/// Scores stretches of a recording straight off disk, a few half-second slices per stretch, so
/// checking a handful of repeated segments never costs a decode of the whole file.
final class AudioFileEnergyProbe: SegmentEnergyProbe {
    private let file: AVAudioFile
    private let duration: Double
    private var loudest: Double?

    init?(url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }
        self.file = file
        duration = Double(file.length) / sampleRate
    }

    /// Measured over windows spread across the whole recording rather than over the segments in
    /// hand: a file whose only sound is the hallucination would otherwise take that as its
    /// reference and rule it loud.
    func loudestEnergy() -> Double {
        if let loudest { return loudest }
        let measured = ProbeWindowPlanner.candidates(duration: duration)
            .compactMap { try? ProbeAudioExtractor.energy(of: $0, in: file) }
            .max() ?? 0
        loudest = measured
        return measured
    }

    func energy(from start: Double, to end: Double) -> Double? {
        let start = max(0, start)
        let end = min(end, duration)
        guard end > start else { return nil }
        return try? ProbeAudioExtractor.energy(
            of: AudioProbeWindow(start: start, duration: end - start),
            in: file
        )
    }
}
