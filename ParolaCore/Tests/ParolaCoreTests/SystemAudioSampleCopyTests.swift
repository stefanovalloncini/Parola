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
        var scratch: AVAudioPCMBuffer?

        let copied = try #require(SystemAudioSampleCopy.copy(
            sampleBuffer: sampleBuffer,
            srcFormat: format,
            frameCount: frames,
            reusing: &scratch
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
        var scratch: AVAudioPCMBuffer?

        let copied = try #require(SystemAudioSampleCopy.copy(
            sampleBuffer: sampleBuffer,
            srcFormat: format,
            frameCount: frames,
            reusing: &scratch
        ))

        #expect(copied.frameLength == frames)
        let channels = try #require(copied.floatChannelData)
        #expect(abs(channels[0][42] - 0.75) < 0.0001)
    }

    @Test("a reused buffer copies a shorter sample buffer after a longer one")
    func reuseAcrossFrameCounts() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        var scratch: AVAudioPCMBuffer?

        let long = try Self.makeSampleBuffer(
            from: Self.makeBuffer(format: format, frames: 960, channelValues: [0.5, -0.25])
        )
        let first = try #require(SystemAudioSampleCopy.copy(
            sampleBuffer: long, srcFormat: format, frameCount: 960, reusing: &scratch
        ))
        #expect(first.frameLength == 960)
        #expect(abs(try #require(first.floatChannelData)[1][100] + 0.25) < 0.0001)

        // The callback rebuilds the format from each sample buffer, so reuse has to survive a fresh equal one.
        let sameFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let short = try Self.makeSampleBuffer(
            from: Self.makeBuffer(format: sameFormat, frames: 480, channelValues: [0.125, -0.75])
        )
        let second = try #require(SystemAudioSampleCopy.copy(
            sampleBuffer: short, srcFormat: sameFormat, frameCount: 480, reusing: &scratch
        ))
        #expect(second === first)
        #expect(second.frameLength == 480)
        let channels = try #require(second.floatChannelData)
        #expect(abs(channels[0][42] - 0.125) < 0.0001)
        #expect(abs(channels[1][42] + 0.75) < 0.0001)
    }

    @Test("a reused tap buffer copies a shorter callback after a longer one")
    func processTapReuseAcrossFrameCounts() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        var scratch: AVAudioPCMBuffer?

        let long = try Self.makeBuffer(format: format, frames: 960, channelValues: [0.5, -0.25])
        let first = try #require(ProcessTapSampleCopy.copy(
            bufferList: long.audioBufferList, srcFormat: format, reusing: &scratch
        ))
        #expect(first.frameLength == 960)
        #expect(abs(try #require(first.floatChannelData)[1][100] + 0.25) < 0.0001)

        let short = try Self.makeBuffer(format: format, frames: 480, channelValues: [0.125, -0.75])
        let second = try #require(ProcessTapSampleCopy.copy(
            bufferList: short.audioBufferList, srcFormat: format, reusing: &scratch
        ))
        #expect(second === first)
        #expect(second.frameLength == 480)
        let channels = try #require(second.floatChannelData)
        #expect(abs(channels[0][42] - 0.125) < 0.0001)
        #expect(abs(channels[1][42] + 0.75) < 0.0001)
    }

    @Test("an empty tap callback copies nothing")
    func processTapEmptyCallback() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        var scratch: AVAudioPCMBuffer?
        let empty = try Self.makeBuffer(format: format, frames: 960, channelValues: [0, 0])
        empty.frameLength = 0

        #expect(ProcessTapSampleCopy.copy(
            bufferList: empty.audioBufferList, srcFormat: format, reusing: &scratch
        ) == nil)
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

    @Test("target matching covers the app and its helper bundles, nothing else")
    @available(macOS 14.2, *)
    func targetBundleMatching() {
        let targets: Set<String> = ["com.microsoft.teams2", "us.zoom.xos"]

        #expect(ProcessTapAudioSource.matchesTarget(bundleID: "com.microsoft.teams2", targets: targets))
        #expect(ProcessTapAudioSource.matchesTarget(bundleID: "com.microsoft.teams2.helper.renderer", targets: targets))
        #expect(ProcessTapAudioSource.matchesTarget(bundleID: "us.zoom.xos", targets: targets))
        #expect(!ProcessTapAudioSource.matchesTarget(bundleID: "com.microsoft.teams22", targets: targets))
        #expect(!ProcessTapAudioSource.matchesTarget(bundleID: "com.apple.Safari", targets: targets))
        #expect(!ProcessTapAudioSource.matchesTarget(bundleID: "com.microsoft.teams2", targets: []))
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
