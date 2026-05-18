import Foundation

public enum WaveformDownsampler {
    public static func downsample(_ samples: [Float], buckets: Int) -> [Float] {
        guard buckets > 0, !samples.isEmpty else { return [] }
        var result = [Float](repeating: 0, count: buckets)
        let count = samples.count
        for index in 0..<buckets {
            let lowerExact = Double(index) * Double(count) / Double(buckets)
            let upperExact = Double(index + 1) * Double(count) / Double(buckets)
            let lower = min(count - 1, max(0, Int(lowerExact.rounded(.down))))
            let upper = min(count, max(lower + 1, Int(upperExact.rounded(.up))))
            var peak: Float = 0
            for i in lower..<upper {
                let amplitude = abs(samples[i])
                if amplitude > peak { peak = amplitude }
            }
            result[index] = peak
        }
        return result
    }
}
