import AVFoundation
import Foundation
import Testing

@testable import ParolaCore

@Suite("Repeated lines over silence")
struct SilentRepetitionsTests {
    @Test("the lead-in copies go and the one over speech stays")
    func dropsTheCopiesOverSilence() throws {
        let url = try Self.writeLeadInSilence()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try #require(AudioFileEnergyProbe(url: url))

        let overSilence = (0..<8).map {
            TranscriptSegment(id: $0, start: Double($0) * 18, end: Double($0) * 18 + 17, text: "Grazie.")
        }
        let overSpeech = TranscriptSegment(id: 8, start: 160, end: 175, text: "Grazie.")

        let out = SilentRepetitions.dropped(from: overSilence + [overSpeech], probe: probe)
        #expect(out == [overSpeech])
    }

    @Test("a repeated line that sits on speech throughout is kept")
    func keepsARepeatedLineOverSpeech() throws {
        let url = try Self.writeLeadInSilence()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try #require(AudioFileEnergyProbe(url: url))

        let segments = [
            TranscriptSegment(id: 0, start: 152, end: 160, text: "Sì."),
            TranscriptSegment(id: 1, start: 162, end: 170, text: "Sì."),
            TranscriptSegment(id: 2, start: 172, end: 180, text: "Sì."),
        ]
        #expect(SilentRepetitions.dropped(from: segments, probe: probe) == segments)
    }

    @Test("two copies are never enough")
    func keepsAPair() throws {
        let url = try Self.writeLeadInSilence()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try #require(AudioFileEnergyProbe(url: url))

        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 40, text: "Grazie."),
            TranscriptSegment(id: 1, start: 60, end: 100, text: "Grazie."),
        ]
        #expect(SilentRepetitions.dropped(from: segments, probe: probe) == segments)
    }

    @Test("grouping ignores case, trailing punctuation and doubled spaces")
    func groupsLooselyEqualText() {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 20, text: "Grazie a tutti."),
            TranscriptSegment(id: 1, start: 20, end: 40, text: "grazie a  tutti"),
            TranscriptSegment(id: 2, start: 40, end: 60, text: " GRAZIE A TUTTI! "),
        ]
        let probe = StubEnergyProbe(loudest: 0.5, quietBefore: 100)
        #expect(SilentRepetitions.dropped(from: segments, probe: probe).isEmpty)
    }

    @Test("a recording with no loud stretch to compare against is left alone")
    func keepsEverythingWhenNothingIsLoud() {
        let segments = (0..<4).map {
            TranscriptSegment(id: $0, start: Double($0) * 20, end: Double($0) * 20 + 19, text: "Grazie.")
        }
        let probe = StubEnergyProbe(loudest: 0, quietBefore: .infinity)
        #expect(SilentRepetitions.dropped(from: segments, probe: probe) == segments)
    }

    @Test("cleanup with no energy probe keeps every repetition")
    func cleanupWithoutAProbeIsUnchanged() {
        let segments = (0..<8).map {
            TranscriptSegment(id: $0, start: Double($0) * 18, end: Double($0) * 18 + 17, text: "Grazie.")
        }
        let transcript = Transcript(segments: segments, language: "it", modelName: "m")
        #expect(TranscriptCleanup.apply(to: transcript).segments == segments)
    }

    private static func writeLeadInSilence() throws -> URL {
        let sampleRate = 8000.0
        let seconds = 200.0
        let speechStart = 150.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let amplitude = time < speechStart ? 0.002 : 0.8
            samples[frame] = Float(sin(2 * .pi * 440 * time) * amplitude)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-repetition-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buffer)
        return url
    }
}

private struct StubEnergyProbe: SegmentEnergyProbe {
    let loudest: Double
    let quietBefore: Double

    func loudestEnergy() -> Double { loudest }

    func energy(from start: Double, to end: Double) -> Double? {
        start < quietBefore ? 0 : loudest
    }
}
