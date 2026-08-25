import AVFoundation
import Foundation
import Testing
@testable import ParolaCore

@Suite("Auto language detection")
struct AutoLanguageDetectionTests {
    @Test("candidates follow the preferred-language order and drop duplicates")
    func candidateOrder() {
        let candidates = LanguageCandidates.autoDetect(
            preferred: ["en-US", "it-IT", "en", "fr-FR"],
            current: Locale(identifier: "en_US")
        )
        #expect(candidates.map(\.identifier) == ["en_US", "it_IT", "fr_FR"])
    }

    @Test("candidates include the language implied by the system region")
    func candidatesIncludeRegionLanguage() {
        let candidates = LanguageCandidates.autoDetect(
            preferred: ["en-US"],
            current: Locale(identifier: "en_US@rg=itzzzz")
        )
        #expect(candidates.map(\.identifier) == ["en_US", "it_IT"])
    }

    @Test("candidates are capped")
    func candidatesCapped() {
        let candidates = LanguageCandidates.autoDetect(
            preferred: ["en-US", "it-IT", "fr-FR", "de-DE", "es-ES", "pt-BR"],
            current: Locale(identifier: "en_US"),
            limit: 4
        )
        #expect(candidates.map(\.identifier) == ["en_US", "it_IT", "fr_FR", "de_DE"])
    }

    @Test("installed matches keep candidate order and drop unavailable languages")
    func installedMatches() {
        let matches = LanguageCandidates.installedMatches(
            for: [Locale(identifier: "it_IT"), Locale(identifier: "sv_SE"), Locale(identifier: "en_US")],
            installed: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")]
        )
        #expect(matches.map(\.identifier) == ["it_IT", "en_US"])
    }

    @Test("installed matches prefer the candidate's own region over another dialect")
    func installedMatchesPreferRegion() {
        let matches = LanguageCandidates.installedMatches(
            for: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
            installed: [
                Locale(identifier: "en_ZA"),
                Locale(identifier: "en_US"),
                Locale(identifier: "it_CH"),
            ]
        )
        #expect(matches.map(\.identifier) == ["en_US", "it_CH"])
    }

    @Test("probe windows spread across a long file and collapse to one on a short file")
    func windowCandidates() {
        let long = ProbeWindowPlanner.candidates(duration: 600, windowSeconds: 20, limit: 5)
        #expect(long.count == 5)
        #expect(long.first?.start == 0)
        #expect(long.last?.end == 600)
        #expect(long.map(\.start) == long.map(\.start).sorted())

        let short = ProbeWindowPlanner.candidates(duration: 12, windowSeconds: 20, limit: 5)
        #expect(short == [AudioProbeWindow(start: 0, duration: 12)])

        #expect(ProbeWindowPlanner.candidates(duration: 0, windowSeconds: 20, limit: 5).isEmpty)
    }

    @Test("window pick takes the loudest windows and returns them in playback order")
    func windowPick() {
        let measured = [
            ProbeWindowEnergy(window: AudioProbeWindow(start: 0, duration: 20), energy: 0.001),
            ProbeWindowEnergy(window: AudioProbeWindow(start: 100, duration: 20), energy: 0.4),
            ProbeWindowEnergy(window: AudioProbeWindow(start: 200, duration: 20), energy: 0.2),
            ProbeWindowEnergy(window: AudioProbeWindow(start: 300, duration: 20), energy: 0.9),
        ]
        let picked = ProbeWindowPlanner.pick(from: measured, limit: 2)
        #expect(picked.map(\.start) == [100, 300])
    }

    @Test("window pick drops near-silent windows even when it needs fewer than the limit")
    func windowPickDropsSilence() {
        let measured = [
            ProbeWindowEnergy(window: AudioProbeWindow(start: 0, duration: 20), energy: 0.5),
            ProbeWindowEnergy(window: AudioProbeWindow(start: 40, duration: 20), energy: 0.000_01),
            ProbeWindowEnergy(window: AudioProbeWindow(start: 80, duration: 20), energy: 0),
        ]
        let picked = ProbeWindowPlanner.pick(from: measured, limit: 3)
        #expect(picked.map(\.start) == [0])
    }

    @Test("window pick on an all-silent file keeps the first windows")
    func windowPickAllSilent() {
        let measured = (0..<4).map {
            ProbeWindowEnergy(window: AudioProbeWindow(start: Double($0) * 20, duration: 20), energy: 0)
        }
        #expect(ProbeWindowPlanner.pick(from: measured, limit: 2).map(\.start) == [0, 20])
    }

    @Test("confidence, not word count, picks the winner")
    func decideDetectsByConfidence() {
        // A recognizer on the wrong language spells the audio out phonetically, so both probes
        // come back with a similar word count; only confidence separates them.
        let pick = AutoLanguage.decide(
            probes: [
                probe("en_US", words: 30, confidence: 0.53),
                probe("it_IT", words: 31, confidence: 0.96),
            ],
            fallback: Locale(identifier: "en_US")
        )
        #expect(pick.locale.identifier == "it_IT")
        #expect(pick.detection == .detected("it"))
    }

    @Test("a lead over a silent runner-up is enough at moderate confidence")
    func decideBeatsSilentRival() {
        // The 10:50 Italian memo: the English probe returns nothing, the Italian one 14 words.
        let pick = AutoLanguage.decide(
            probes: [
                probe("en_US", words: 3, confidence: 0.34),
                probe("it_IT", words: 14, confidence: 0.77),
            ],
            fallback: Locale(identifier: "en_US")
        )
        #expect(pick.locale.identifier == "it_IT")
        #expect(pick.detection == .detected("it"))
    }

    @Test("a thin probe keeps the best locale but stays assumed")
    func decideThinProbe() {
        let pick = AutoLanguage.decide(
            probes: [
                probe("it_IT", words: 2, confidence: 0.9),
                probe("fr_FR", words: 0, confidence: nil),
            ],
            fallback: Locale(identifier: "en_US")
        )
        #expect(pick.locale.identifier == "it_IT")
        #expect(pick.detection == .assumed("it"))
    }

    @Test("a mumbled winner stays assumed however far ahead it is")
    func decideWeakWinner() {
        let pick = AutoLanguage.decide(
            probes: [
                probe("es_ES", words: 30, confidence: 0.2),
                probe("it_IT", words: 28, confidence: 0.45),
            ],
            fallback: Locale(identifier: "en_US")
        )
        #expect(pick.locale.identifier == "it_IT")
        #expect(pick.detection == .assumed("it"))
    }

    @Test("two recognizers that both nail the audio are not a stand-off")
    func decideBothConfident() {
        // Apple's locales are not strictly monolingual: it_IT transcribes clear English at 0.92.
        // Either pick produces the same transcript, so the thin margin is not a reason to warn.
        let pick = AutoLanguage.decide(
            probes: [
                probe("en_US", words: 29, confidence: 0.96),
                probe("it_IT", words: 29, confidence: 0.92),
            ],
            fallback: Locale(identifier: "en_US")
        )
        #expect(pick.locale.identifier == "en_US")
        #expect(pick.detection == .detected("en"))
    }

    @Test("word yield decides when the engine reports no confidence")
    func decideWithoutConfidence() {
        let pick = AutoLanguage.decide(
            probes: [
                probe("en_US", words: 9, confidence: nil),
                probe("it_IT", words: 40, confidence: nil),
            ],
            fallback: Locale(identifier: "en_US")
        )
        #expect(pick.detection == .detected("it"))
    }

    @Test("a close word yield without confidence is assumed")
    func decideCloseYieldWithoutConfidence() {
        let pick = AutoLanguage.decide(
            probes: [
                probe("en_US", words: 30, confidence: nil),
                probe("it_IT", words: 31, confidence: nil),
            ],
            fallback: Locale(identifier: "en_US")
        )
        #expect(pick.locale.identifier == "it_IT")
        #expect(pick.detection == .assumed("it"))
    }

    @Test("probes that produce nothing at all leave the fallback in place")
    func decideNothingRecognized() {
        let pick = AutoLanguage.decide(
            probes: [
                probe("it_IT", words: 0, confidence: nil),
                probe("fr_FR", words: 0, confidence: nil),
            ],
            fallback: Locale(identifier: "en_US")
        )
        #expect(pick.locale.identifier == "en_US")
        #expect(pick.detection == .assumed("en"))
    }

    @Test("no probes at all is an assumed fallback")
    func decideNoProbes() {
        let pick = AutoLanguage.decide(probes: [], fallback: Locale(identifier: "de_DE"))
        #expect(pick.detection == .assumed("de"))
    }

    @Test("a single candidate never runs a probe")
    func pickerSkipsSingleCandidate() async throws {
        let calls = Counter()
        let picker = AutoLanguagePicker { locale in
            await calls.record(locale.identifier)
            return LanguageProbeOutcome(text: "whatever", confidence: 0.9)
        }
        let pick = try await picker.pick(
            candidates: [Locale(identifier: "en_US")],
            fallback: Locale(identifier: "en_US")
        )
        #expect(pick.detection == .assumed("en"))
        #expect(await calls.recorded.isEmpty)
    }

    @Test("a failing probe does not sink the other candidates")
    func pickerSurvivesProbeFailure() async throws {
        let picker = AutoLanguagePicker { locale in
            if locale.identifier == "en_US" { throw ParolaError.transcriptionFailed("no asset") }
            return LanguageProbeOutcome(text: String(repeating: "parola ", count: 30), confidence: 0.95)
        }
        let pick = try await picker.pick(
            candidates: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
            fallback: Locale(identifier: "en_US")
        )
        #expect(pick.detection == .detected("it"))
    }

    @Test("picker probes every candidate in order")
    func pickerProbesEachCandidate() async throws {
        let calls = Counter()
        let picker = AutoLanguagePicker { locale in
            await calls.record(locale.identifier)
            return locale.identifier == "it_IT"
                ? LanguageProbeOutcome(text: String(repeating: "parola ", count: 30), confidence: 0.95)
                : LanguageProbeOutcome(text: "uh uh uh uh uh uh", confidence: 0.3)
        }
        let pick = try await picker.pick(
            candidates: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
            fallback: Locale(identifier: "en_US")
        )
        #expect(await calls.recorded == ["en_US", "it_IT"])
        #expect(pick.detection == .detected("it"))
    }

    @Test("picker propagates cancellation instead of scoring a half-finished set")
    func pickerPropagatesCancellation() async {
        let picker = AutoLanguagePicker { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await picker.pick(
                candidates: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
                fallback: Locale(identifier: "en_US")
            )
        }
    }

    @Test("a chosen language reports nothing about detection")
    func resolutionSpecified() {
        let resolution = LocaleResolution.specified(Locale(identifier: "it_IT"))
        #expect(resolution.locale.identifier == "it_IT")
        #expect(resolution.needsRunConfidence == false)
        #expect(resolution.detection(afterRun: 0.2, isEmpty: false) == nil)
    }

    @Test("an unverifiable run stays quiet when the transcript comes out clean")
    func resolutionUnverifiedAndConfident() {
        let resolution = LocaleResolution.unverified(Locale(identifier: "en_US"))
        #expect(resolution.needsRunConfidence)
        #expect(resolution.detection(afterRun: 0.94, isEmpty: false) == nil)
        #expect(resolution.detection(afterRun: nil, isEmpty: false) == nil)
    }

    @Test("an unverifiable run that comes out weak or empty is flagged as assumed")
    func resolutionUnverifiedAndWeak() {
        let resolution = LocaleResolution.unverified(Locale(identifier: "en_US"))
        #expect(resolution.detection(afterRun: 0.4, isEmpty: false) == .assumed("en"))
        #expect(resolution.detection(afterRun: nil, isEmpty: true) == .assumed("en"))
    }

    @Test("a probed run reports the probe verdict whatever the run confidence")
    func resolutionProbed() {
        let resolution = LocaleResolution.probed(
            LanguagePick(locale: Locale(identifier: "it_IT"), detection: .detected("it"))
        )
        #expect(resolution.locale.identifier == "it_IT")
        #expect(resolution.needsRunConfidence == false)
        #expect(resolution.detection(afterRun: 0.3, isEmpty: false) == .detected("it"))
    }

    @Test("detection round-trips through JSON with a readable shape")
    func detectionCodable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(LanguageDetection.assumed("en"))
        #expect(String(decoding: data, as: UTF8.self) == #"{"code":"en","status":"assumed"}"#)
        let decoded = try JSONDecoder().decode(LanguageDetection.self, from: data)
        #expect(decoded == .assumed("en"))
        #expect(decoded.isAssumed)
        #expect(decoded.code == "en")
        #expect(LanguageDetection.detected("it").isAssumed == false)
    }

    @Test("a transcript saved before the field existed still decodes")
    func transcriptBackwardCompatible() throws {
        let json = #"{"segments":[],"language":"it","modelName":"m","schemaVersion":1}"#
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        #expect(transcript.languageDetection == nil)
    }

    @Test("probe extraction keeps the loud stretch and skips the silence")
    func extractionPicksLoudWindow() throws {
        let sampleRate = 8000.0
        let url = try Self.writeTone(
            sampleRate: sampleRate,
            seconds: 60,
            loudRange: 30..<40
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-probe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: probeURL) }

        let windows = try ProbeAudioExtractor.extract(
            from: url,
            to: probeURL,
            windowSeconds: 10,
            windowLimit: 1,
            candidateLimit: 6
        )
        #expect(windows.count == 1)
        let start = try #require(windows.first?.start)
        #expect(start >= 25 && start <= 40)

        let written = try AVAudioFile(forReading: probeURL)
        let duration = Double(written.length) / written.processingFormat.sampleRate
        #expect(abs(duration - 10) < 0.2)
    }

    @Test("a stereo source with sound on one side only is extracted as audible mono")
    func extractionDownmixesStereo() throws {
        let url = try Self.writeTone(sampleRate: 8000, seconds: 6, loudRange: 0..<6, channels: 2, loudChannel: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-probe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: probeURL) }

        let windows = try ProbeAudioExtractor.extract(
            from: url,
            to: probeURL,
            windowSeconds: 10,
            windowLimit: 1,
            candidateLimit: 4
        )
        #expect(windows == [AudioProbeWindow(start: 0, duration: 6)])

        let written = try AVAudioFile(forReading: probeURL)
        #expect(written.processingFormat.channelCount == 1)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: written.processingFormat, frameCapacity: AVAudioFrameCount(written.length))
        )
        try written.read(into: buffer)
        let peak = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
        #expect(peak > 0.2)
    }

    private func probe(_ identifier: String, words: Int, confidence: Double?) -> LanguageProbe {
        LanguageProbe(
            locale: Locale(identifier: identifier),
            outcome: LanguageProbeOutcome(
                text: (0..<words).map { "w\($0)" }.joined(separator: " "),
                confidence: confidence
            )
        )
    }

    private static func writeTone(
        sampleRate: Double,
        seconds: Double,
        loudRange: Range<Double>,
        channels: AVAudioChannelCount = 1,
        loudChannel: Int? = nil
    ) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            let silent = loudChannel.map { $0 != channel } ?? false
            for frame in 0..<Int(frameCount) {
                let time = Double(frame) / sampleRate
                let loud = !silent && loudRange.contains(time)
                samples[frame] = loud ? Float(sin(2 * .pi * 440 * time)) * 0.8 : 0
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-probe-src-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buffer)
        return url
    }
}

private actor Counter {
    private(set) var recorded: [String] = []
    func record(_ value: String) { recorded.append(value) }
}
