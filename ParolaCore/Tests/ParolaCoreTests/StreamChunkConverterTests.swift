import AVFoundation
import Testing
@testable import ParolaCore

@Suite("Stream chunk converter")
struct StreamChunkConverterTests {
    @Test("a persistent converter keeps producing frames across many chunks")
    func persistentConverterSurvivesChunks() throws {
        let src = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let dst = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let converter = try #require(AVAudioConverter(from: src, to: dst))

        var total: AVAudioFrameCount = 0
        for i in 0..<10 {
            let chunk = try #require(AVAudioPCMBuffer(pcmFormat: src, frameCapacity: 4096))
            chunk.frameLength = 4096
            for ch in 0..<Int(src.channelCount) {
                let samples = chunk.floatChannelData![ch]
                for f in 0..<4096 { samples[f] = sinf(Float(i * 4096 + f) * 0.01) }
            }
            if let out = StreamChunkConverter.convert(chunk: chunk, with: converter, to: dst) {
                total += out.frameLength
            }
        }

        // 10 chunks x 4096 frames at a 3:1 downsample is ~13,650 frames; leave slack for
        // resampler tail buffering. The latched-converter bug yields ~1,365 (first chunk only).
        #expect(total > 12_000)
    }

    @Test("a single chunk converts without loss")
    func singleChunkConverts() throws {
        let src = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let dst = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let converter = try #require(AVAudioConverter(from: src, to: dst))
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: src, frameCapacity: 4800))
        chunk.frameLength = 4800

        let out = try #require(StreamChunkConverter.convert(chunk: chunk, with: converter, to: dst))
        #expect(out.frameLength > 1_000)
        #expect(out.format.sampleRate == 16_000)
        #expect(out.format.channelCount == 1)
    }
}
