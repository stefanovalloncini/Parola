import Foundation
import Testing
@testable import ParolaCore

@Suite("Waveform downsampler")
struct WaveformDownsamplerTests {
    @Test("returns the requested bucket count")
    func bucketCount() {
        let samples = Array(repeating: Float(0.5), count: 1000)
        let out = WaveformDownsampler.downsample(samples, buckets: 10)
        #expect(out.count == 10)
    }

    @Test("each bucket reports the peak absolute amplitude")
    func peakAmplitude() {
        var samples = Array(repeating: Float(0.1), count: 100)
        samples[42] = 0.9
        let out = WaveformDownsampler.downsample(samples, buckets: 10)
        let max = out.max() ?? 0
        #expect(max == 0.9)
    }

    @Test("handles negative amplitudes via absolute value")
    func absolute() {
        let samples: [Float] = [-0.7, 0.3, -0.1, 0.2]
        let out = WaveformDownsampler.downsample(samples, buckets: 2)
        #expect(out[0] == 0.7)
        #expect(out[1] == 0.2)
    }

    @Test("zero or negative buckets returns empty")
    func zeroBuckets() {
        let samples: [Float] = [0.1, 0.2]
        #expect(WaveformDownsampler.downsample(samples, buckets: 0).isEmpty)
    }

    @Test("empty input returns empty")
    func emptyInput() {
        let out: [Float] = WaveformDownsampler.downsample([], buckets: 5)
        #expect(out.isEmpty)
    }

    @Test("works when bucket count exceeds sample count")
    func moreBucketsThanSamples() {
        let samples: [Float] = [0.4, 0.7]
        let out = WaveformDownsampler.downsample(samples, buckets: 5)
        #expect(out.count == 5)
        let nonZero = out.filter { $0 > 0 }
        #expect(!nonZero.isEmpty)
    }
}
