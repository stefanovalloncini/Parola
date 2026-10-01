import Foundation
import Testing
import ParolaTestSupport
@testable import ParolaCore

@Suite("Speaker side attribution")
struct SpeakerSideAttributionTests {
    @Test("a segment that is loud on your side is labelled Me")
    func meWhenMicDominates() throws {
        let stereo = try TestAudio.stereo(leftAmplitude: 0.02, rightAmplitude: 0.5, seconds: 4)
        defer { try? FileManager.default.removeItem(at: stereo) }
        let segments = [TranscriptSegment(id: 0, start: 0, end: 4, text: "Hi everyone")]
        let labelled = try SpeakerSideAttribution.label(segments: segments, stereo: stereo, meLabel: "Me")
        #expect(labelled.first?.speaker == "Me")
    }

    @Test("a segment loud on the Mac side keeps its speaker")
    func othersKeepTheirLabel() throws {
        let stereo = try TestAudio.stereo(leftAmplitude: 0.5, rightAmplitude: 0.02, seconds: 4)
        defer { try? FileManager.default.removeItem(at: stereo) }
        let segments = [TranscriptSegment(id: 0, start: 0, end: 4, text: "Hello", speaker: "Speaker 2")]
        let labelled = try SpeakerSideAttribution.label(segments: segments, stereo: stereo, meLabel: "Me")
        #expect(labelled.first?.speaker == "Speaker 2")
    }

    @Test("your side has to be six decibels louder: a little under keeps the speaker, a little over is Me")
    func sixDecibelRule() throws {
        let under = try TestAudio.stereo(leftAmplitude: 0.1, rightAmplitude: 0.19, seconds: 2)
        let over = try TestAudio.stereo(leftAmplitude: 0.1, rightAmplitude: 0.21, seconds: 2)
        defer { for file in [under, over] { try? FileManager.default.removeItem(at: file) } }
        let segments = [TranscriptSegment(id: 0, start: 0, end: 2, text: "Both talking", speaker: "Speaker 1")]

        #expect(try SpeakerSideAttribution.label(segments: segments, stereo: under, meLabel: "Me").first?.speaker == "Speaker 1")
        #expect(try SpeakerSideAttribution.label(segments: segments, stereo: over, meLabel: "Me").first?.speaker == "Me")
    }

    @Test("room noise under a silent stretch is nobody's, however quiet the Mac side is")
    func silenceIsNobodys() throws {
        let stereo = try TestAudio.stereo(leftAmplitude: 0.0001, rightAmplitude: 0.003, seconds: 2)
        defer { try? FileManager.default.removeItem(at: stereo) }
        let segments = [TranscriptSegment(id: 0, start: 0, end: 2, text: "Thank you.")]

        let labelled = try SpeakerSideAttribution.label(segments: segments, stereo: stereo, meLabel: "Me")

        #expect(labelled.first?.speaker == nil)
    }

    @Test("each segment is judged on its own stretch of the take")
    func eachSegmentOnItsOwn() throws {
        let rate = TestAudio.sampleRate
        let loud = TestAudio.sine(seconds: 2, hz: 220, amplitude: 0.5)
        let quiet = TestAudio.sine(seconds: 2, hz: 440, amplitude: 0.01)
        let stereo = FileManager.default.temporaryDirectory.appendingPathComponent("parola-test-sides-\(UUID().uuidString).wav")
        try TestAudio.write(channels: [quiet + loud, loud + quiet], sampleRate: rate, to: stereo)
        defer { try? FileManager.default.removeItem(at: stereo) }
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 2, text: "Mine", speaker: "Speaker 1"),
            TranscriptSegment(id: 1, start: 2, end: 4, text: "Theirs", speaker: "Speaker 1"),
        ]

        let labelled = try SpeakerSideAttribution.label(segments: segments, stereo: stereo, meLabel: "Io")

        #expect(labelled.map(\.speaker) == ["Io", "Speaker 1"])
        #expect(labelled.map(\.text) == ["Mine", "Theirs"])
    }

    @Test("the words of a segment that becomes Me follow it, where they carried a speaker")
    func wordsFollowTheirSegment() throws {
        let stereo = try TestAudio.stereo(leftAmplitude: 0.02, rightAmplitude: 0.5, seconds: 2)
        defer { try? FileManager.default.removeItem(at: stereo) }
        let diarized = TranscriptSegment(id: 0, start: 0, end: 1, text: "Good morning", speaker: "Speaker 1", words: [
            WordTiming(id: "0-0", word: "Good", start: 0, end: 0.4, probability: 1, speaker: "Speaker 1"),
            WordTiming(id: "0-1", word: "morning", start: 0.4, end: 1, probability: 1, speaker: "Speaker 1"),
        ])
        let plain = TranscriptSegment(id: 1, start: 1, end: 2, text: "all", words: [
            WordTiming(id: "1-0", word: "all", start: 1, end: 2, probability: 1),
        ])

        let labelled = try SpeakerSideAttribution.label(segments: [diarized, plain], stereo: stereo, meLabel: "Me")

        #expect(labelled[0].words?.map(\.speaker) == ["Me", "Me"])
        #expect(labelled[1].speaker == "Me")
        #expect(labelled[1].words?.map(\.speaker) == [nil], "a word that carried no speaker gets none")
    }

    @Test("a file with one channel has no sides, so every segment keeps its speaker")
    func monoHasNoSides() throws {
        let mono = FileManager.default.temporaryDirectory.appendingPathComponent("parola-test-mono-\(UUID().uuidString).wav")
        try TestAudio.tone(seconds: 1, hz: 220, amplitude: 0.5, at: mono)
        defer { try? FileManager.default.removeItem(at: mono) }
        let segments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello", speaker: "Speaker 3")]

        #expect(try SpeakerSideAttribution.label(segments: segments, stereo: mono, meLabel: "Me") == segments)
    }
}
