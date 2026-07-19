#if os(macOS)
import Foundation
import Testing
import AVFoundation
import CoreMedia
@testable import ParolaCore

@Suite("SystemAudioSampleCopy")
struct SystemAudioSampleCopyTests {

    @Test("copies the deinterleaved stereo buffers ScreenCaptureKit delivers")
    func deinterleavedStereo() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let frames: AVAudioFrameCount = 960
        let source = try Self.makeBuffer(format: format, frames: frames, channelValues: [0.5, -0.25])
        let sampleBuffer = try Self.makeSampleBuffer(from: source)

        let copied = try #require(SystemAudioSampleCopy.copy(
            sampleBuffer: sampleBuffer,
            srcFormat: format,
            frameCount: frames
        ))

        #expect(copied.frameLength == frames)
        let channels = try #require(copied.floatChannelData)
        #expect(abs(channels[0][100] - 0.5) < 0.0001)
        #expect(abs(channels[1][100] + 0.25) < 0.0001)
    }

    @Test("copies mono buffers")
    func mono() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frames: AVAudioFrameCount = 480
        let source = try Self.makeBuffer(format: format, frames: frames, channelValues: [0.75])
        let sampleBuffer = try Self.makeSampleBuffer(from: source)

        let copied = try #require(SystemAudioSampleCopy.copy(
            sampleBuffer: sampleBuffer,
            srcFormat: format,
            frameCount: frames
        ))

        #expect(copied.frameLength == frames)
        let channels = try #require(copied.floatChannelData)
        #expect(abs(channels[0][42] - 0.75) < 0.0001)
    }

    private static func makeBuffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        channelValues: [Float]
    ) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for (ch, value) in channelValues.enumerated() {
            for i in 0..<Int(frames) {
                channels[ch][i] = value
            }
        }
        return buffer
    }

    private static func makeSampleBuffer(from pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var asbd = pcm.format.streamDescription.pointee
        var formatDesc: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        #expect(status == noErr)

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(pcm.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        #expect(status == noErr)
        let buffer = try #require(sampleBuffer)

        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        )
        #expect(status == noErr)
        return buffer
    }
}
#endif
