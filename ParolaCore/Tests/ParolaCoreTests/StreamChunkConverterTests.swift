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

    @Test("a reused output buffer yields the same frames as a fresh one")
    func reusedOutputMatchesFreshOutput() throws {
        let src = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let dst = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let fresh = try #require(AVAudioConverter(from: src, to: dst))
        let reusing = try #require(AVAudioConverter(from: src, to: dst))
        var scratch: AVAudioPCMBuffer?

        for i in 0..<8 {
            let chunk = try Self.tone(format: src, frames: 4096, phase: i * 4096)
            let a = try #require(StreamChunkConverter.convert(chunk: chunk, with: fresh, to: dst))
            let b = try #require(StreamChunkConverter.convert(
                chunk: chunk, with: reusing, to: dst, reusing: &scratch
            ))
            #expect(a.frameLength == b.frameLength)
            let left = try #require(a.floatChannelData)
            let right = try #require(b.floatChannelData)
            for f in 0..<Int(a.frameLength) {
                #expect(left[0][f] == right[0][f])
            }
        }
    }

    @Test("the scratch buffer is kept for equal chunks and grown for larger ones")
    func scratchGrowsOnlyWhenNeeded() throws {
        let src = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let dst = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let converter = try #require(AVAudioConverter(from: src, to: dst))
        var scratch: AVAudioPCMBuffer?

        let first = try #require(StreamChunkConverter.convert(
            chunk: try Self.tone(format: src, frames: 4096, phase: 0), with: converter, to: dst, reusing: &scratch
        ))
        let second = try #require(StreamChunkConverter.convert(
            chunk: try Self.tone(format: src, frames: 4096, phase: 4096), with: converter, to: dst, reusing: &scratch
        ))
        #expect(first === second)

        let grown = try #require(StreamChunkConverter.convert(
            chunk: try Self.tone(format: src, frames: 32_768, phase: 0), with: converter, to: dst, reusing: &scratch
        ))
        #expect(grown !== first)
        #expect(grown.frameCapacity > first.frameCapacity)
    }

    private static func tone(format: AVAudioFormat, frames: AVAudioFrameCount, phase: Int) throws -> AVAudioPCMBuffer {
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        chunk.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let samples = chunk.floatChannelData![ch]
            for f in 0..<Int(frames) { samples[f] = sinf(Float(phase + f) * 0.01) }
        }
        return chunk
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
