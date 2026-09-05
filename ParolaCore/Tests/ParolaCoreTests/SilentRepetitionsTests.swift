import AVFoundation
import Clocks
import Foundation
import Testing

@testable import ParolaCore

@Suite("Repeated lines over silence")
struct SilentRepetitionsTests {
    @Test("the lead-in copies go and the one over speech stays")
    func dropsTheCopiesOverSilence() throws {
        let url = try LeadInSilenceFixture.write()
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
        let url = try LeadInSilenceFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try #require(AudioFileEnergyProbe(url: url))

        let segments = [
            TranscriptSegment(id: 0, start: 152, end: 160, text: "Sì."),
            TranscriptSegment(id: 1, start: 162, end: 170, text: "Sì."),
            TranscriptSegment(id: 2, start: 172, end: 180, text: "Sì."),
        ]
        #expect(SilentRepetitions.dropped(from: segments, probe: probe) == segments)
    }

    @Test("one loud transient does not lift the floor into the speech band")
    func keepsSpeechLevelRepeatsDespiteATransient() throws {
        let url = try LeadInSilenceFixture.write(speechAmplitude: 0.05, transientAt: 120)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try #require(AudioFileEnergyProbe(url: url))

        let overSpeech = (0..<3).map {
            TranscriptSegment(id: $0, start: 152 + Double($0) * 10, end: 160 + Double($0) * 10, text: "Sì.")
        }
        let overSilence = (3..<6).map {
            TranscriptSegment(id: $0, start: Double($0) * 18, end: Double($0) * 18 + 17, text: "Grazie.")
        }
        let out = SilentRepetitions.dropped(from: overSpeech + overSilence, probe: probe)
        #expect(out == overSpeech)
    }

    @Test("two copies are never enough")
    func keepsAPair() throws {
        let url = try LeadInSilenceFixture.write()
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
        #expect(SilentRepetitions.dropped(from: segments, probe: StubEnergyProbe()).isEmpty)
    }

    @Test("segments that normalize to nothing are never candidates")
    func keepsPunctuationOnlySegments() {
        let segments = (0..<4).map {
            TranscriptSegment(id: $0, start: Double($0) * 20, end: Double($0) * 20 + 19, text: "...")
        }
        #expect(SilentRepetitions.dropped(from: segments, probe: StubEnergyProbe()) == segments)
    }

    @Test("a recording with no loud stretch to compare against is left alone")
    func keepsEverythingWhenNothingIsLoud() {
        let segments = (0..<4).map {
            TranscriptSegment(id: $0, start: Double($0) * 20, end: Double($0) * 20 + 19, text: "Grazie.")
        }
        let probe = StubEnergyProbe(windows: [0, 0, 0])
        #expect(SilentRepetitions.dropped(from: segments, probe: probe) == segments)
    }

    @Test("a lone transient is capped out of the floor")
    func floorIgnoresALoneTransient() throws {
        let speech = 0.02
        let windows = Array(repeating: speech, count: 23) + [0.5]
        let floor = try #require(SilentRepetitions.floor(forWindows: windows))
        #expect(floor < speech)

        let segments = (0..<3).map {
            TranscriptSegment(id: $0, start: Double($0) * 20, end: Double($0) * 20 + 19, text: "Sì.")
        }
        let probe = StubEnergyProbe(windows: windows, quietBefore: 0, speechEnergy: speech)
        #expect(SilentRepetitions.dropped(from: segments, probe: probe) == segments)
    }

    /// The 24 window levels measured off the 159 memo. The lead-in hallucinations there run
    /// 0.0024–0.0124 and its quietest real speech is 0.066, so the floor has to sit between them
    /// with room to spare on the speech side.
    @Test("the floor clears the 159 memo's measurements at both ends")
    func floorMatchesTheMemoMeasurements() throws {
        let windows = [
            0.19934, 0.00676, 0.10335, 0.00431, 0.00515, 0.03427, 0.05538, 0.03065,
            0.01200, 0.01776, 0.02233, 0.01234, 0.01482, 0.02257, 0.04441, 0.03148,
            0.01264, 0.01576, 0.02202, 0.01018, 0.00615, 0.01831, 0.07960, 0.18455,
        ]
        let floor = try #require(SilentRepetitions.floor(forWindows: windows))
        #expect(floor > 0.0124)
        #expect(floor * 3 < 0.066)
    }

    @Test("cleanup with no energy probe keeps every repetition")
    func cleanupWithoutAProbeIsUnchanged() {
        let segments = (0..<8).map {
            TranscriptSegment(id: $0, start: Double($0) * 18, end: Double($0) * 18 + 17, text: "Grazie.")
        }
        let transcript = Transcript(segments: segments, language: "it", modelName: "m")
        #expect(TranscriptCleanup.apply(to: transcript).segments == segments)
    }

    @Test("cleanup drops blanks and quiet repetitions and keeps the rest")
    func cleanupDropsBlanksAndQuietRepeats() {
        let out = TranscriptCleanup.apply(
            to: Self.mixedTranscript,
            options: TranscriptCleanupOptions(),
            energy: StubEnergyProbe(quietBefore: 100)
        )
        #expect(out.segments.map(\.text) == ["Buongiorno a tutti"])
    }

    @Test("turning hallucination filtering off turns this off too")
    func cleanupRespectsTheHallucinationSwitch() {
        let out = TranscriptCleanup.apply(
            to: Self.mixedTranscript,
            options: TranscriptCleanupOptions(filtersHallucinations: false),
            energy: StubEnergyProbe(quietBefore: 100)
        )
        #expect(out.segments.map(\.text) == [
            "Grazie.", "Grazie.", "Grazie.", "Sottotitoli a cura di QTSS", "Buongiorno a tutti",
        ])
    }

    private static let mixedTranscript = Transcript(
        segments: [
            TranscriptSegment(id: 0, start: 0, end: 9, text: "  "),
            TranscriptSegment(id: 1, start: 10, end: 19, text: "Grazie."),
            TranscriptSegment(id: 2, start: 20, end: 29, text: "Grazie."),
            TranscriptSegment(id: 3, start: 30, end: 39, text: ""),
            TranscriptSegment(id: 4, start: 40, end: 49, text: "Grazie."),
            TranscriptSegment(id: 5, start: 50, end: 59, text: "Sottotitoli a cura di QTSS"),
            TranscriptSegment(id: 6, start: 200, end: 209, text: "Buongiorno a tutti"),
        ],
        language: "it",
        modelName: "m"
    )
}

/// A recording that opens with two and a half minutes of room tone and only then has someone
/// speaking, optionally with one loud thump dropped into the quiet part.
enum LeadInSilenceFixture {
    static let speechStart = 150.0

    static func write(
        seconds: Double = 200,
        roomAmplitude: Double = 0.002,
        speechAmplitude: Double = 0.8,
        transientAt: Double? = nil,
        transientSeconds: Double = 2
    ) throws -> URL {
        let sampleRate = 8000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            var amplitude = time < speechStart ? roomAmplitude : speechAmplitude
            if let transientAt, time >= transientAt, time < transientAt + transientSeconds {
                amplitude = 0.9
            }
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
    var windows: [Double] = [0.5]
    var quietBefore: Double = .infinity
    var speechEnergy: Double = 0.5

    func windowEnergies() -> [Double] { windows }

    func energy(from start: Double, to end: Double) -> Double? {
        start < quietBefore ? 0 : speechEnergy
    }
}

@Suite("Repeated lines over silence in a session")
struct SessionSilentRepetitionsTests {
    private let seeds =
        (0..<3).map {
            TranscriptSegmentSeed(start: Double($0) * 18, end: Double($0) * 18 + 17, text: "Grazie.")
        } + [TranscriptSegmentSeed(start: 160, end: 175, text: "Ecco, ci siamo.")]

    @Test("a Whisper run drops the copies over the lead-in")
    func whisperRunDropsTheCopies() async throws {
        let (session, audioURL) = try await makeSession(engineID: .whisperKit, model: "openai_whisper-tiny")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )
        await session.unloadModel()

        #expect(transcript.segments.map(\.text) == ["Ecco, ci siamo."])
    }

    @Test("another engine's repetitions are left as the engine made them")
    func otherEnginesKeepTheirRepetitions() async throws {
        let (session, audioURL) = try await makeSession(
            engineID: .parakeet, model: "nvidia_parakeet-tdt-0.6b-v2"
        )
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v2", language: "en")
        )
        await session.unloadModel()

        #expect(transcript.segments.count == 4)
    }

    private func makeSession(
        engineID: EngineID,
        model: String
    ) async throws -> (session: TranscriptionSession, audioURL: URL) {
        let registry = EngineRegistry()
        let response = MockTranscriberResponse(segments: seeds, language: "it", modelName: "mock")
        await registry.register(
            engineID: engineID,
            capabilities: .whisperKitDefaults,
            factory: { _ in MockTranscriber.make(response: response, clock: ImmediateClock()) }
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-repetition-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel(model)
        return (
            TranscriptionSession(modelStore: store, registry: registry),
            try LeadInSilenceFixture.write()
        )
    }
}
