import AVFoundation
import Foundation
import Testing
@testable import ParolaCore

@Suite("Per-call hygiene")
struct IdleHygieneTests {
    private func segments(_ texts: [String]) -> [TranscriptSegment] {
        texts.enumerated().map { TranscriptSegment(id: $0.offset, start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element) }
    }

    @Test("textHasAtLeast agrees with the length of text")
    func textLengthAgrees() {
        let cases: [[String]] = [
            [], [""], ["   "], ["short"], ["  padded  ", "", "second   "], ["héllo wörld", "🙂🙂🙂", "e\u{301}"],
            [String(repeating: "a", count: 39)], [String(repeating: "a", count: 40)],
            [String(repeating: "a", count: 20), String(repeating: "b", count: 19)],
            [String(repeating: "a", count: 20), String(repeating: "b", count: 20)],
        ]
        for texts in cases {
            let transcript = Transcript(segments: segments(texts), language: "en", modelName: "tiny")
            let length = transcript.text.count
            for threshold in [0, 1, length - 1, length, length + 1, 40] where threshold >= 0 {
                #expect(transcript.textHasAtLeast(characters: threshold) == (length >= threshold), "\(texts) at \(threshold)")
            }
        }
    }

    @available(macOS 26.0, *)
    @Test("the chat delta slices by bytes and stays on character boundaries")
    func chatDelta() throws {
        #expect(FoundationLanguageModel.delta(of: "Hello", after: 0)?.text == "Hello")
        let step = try #require(FoundationLanguageModel.delta(of: "Hello wörld 🙂", after: 5))
        #expect(step.text == " wörld 🙂")
        #expect(step.bytes == "Hello wörld 🙂".utf8.count)
        #expect(FoundationLanguageModel.delta(of: "Hello", after: 5) == nil)
        #expect(FoundationLanguageModel.delta(of: "Hel", after: 5) == nil)
        #expect(FoundationLanguageModel.delta(of: "wö", after: 2) == nil, "a cut inside a scalar is not a delta")
    }

    @Test("one AVAudioFormat serves every buffer of a description, and a new description makes a new one")
    func sourceFormatIsReused() throws {
        let box = CacheBox()
        var stereo = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        let first = try #require(box.format(for: stereo))
        let second = try #require(box.format(for: stereo))
        #expect(first === second)
        stereo.mSampleRate = 44_100
        let third = try #require(box.format(for: stereo))
        #expect(third !== first)
        #expect(third.sampleRate == 44_100)
    }
}

private final class CacheBox {
    private var cache = SourceFormatCache()
    func format(for description: AudioStreamBasicDescription) -> AVAudioFormat? { cache.format(for: description) }
}
