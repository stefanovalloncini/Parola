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

        #expect(
            ProbeWindowPlanner.candidates(duration: 30, windowSeconds: 20, limit: 5)
                == [AudioProbeWindow(start: 0, duration: 30)],
            "a file under two windows long is probed whole, tail included"
        )
        #expect(
            ProbeWindowPlanner.candidates(duration: 40, windowSeconds: 20, limit: 5)
                == [AudioProbeWindow(start: 0, duration: 40)]
        )
        let justPast = ProbeWindowPlanner.candidates(duration: 41, windowSeconds: 20, limit: 5)
        #expect(justPast.count == 2)
        #expect(justPast.last?.end == 41)

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
        let picker = AutoLanguagePicker(windowCount: 2) { locale, _ in
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
        let picker = AutoLanguagePicker(windowCount: 2) { locale, _ in
            if locale.identifier == "en_US" { throw ParolaError.transcriptionFailed("no asset") }
            return Self.speech
        }
        let pick = try await picker.pick(
            candidates: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
            fallback: Locale(identifier: "en_US")
        )
        #expect(pick.detection == .detected("it"))
    }

    @Test("picker probes every candidate on a window before the next window")
    func pickerProbesEachCandidate() async throws {
        let calls = Counter()
        let picker = AutoLanguagePicker(windowCount: 2, concurrentProbes: 1) { locale, window in
            await calls.record("\(window) \(locale.identifier)")
            return locale.identifier == "it_IT" ? Self.speech : Self.mumble
        }
        let pick = try await picker.pick(
            candidates: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
            fallback: Locale(identifier: "en_US")
        )
        #expect(await calls.recorded == ["0 en_US", "0 it_IT", "1 en_US", "1 it_IT"])
        #expect(pick.detection == .detected("it"))
    }

    @Test("two windows that agree end the probe")
    func pickerStopsOnceTwoWindowsAgree() async throws {
        let calls = Counter()
        let picker = AutoLanguagePicker(windowCount: 6, concurrentProbes: 1) { locale, window in
            await calls.record("\(window) \(locale.identifier)")
            return locale.identifier == "it_IT" ? Self.speech : Self.mumble
        }
        let pick = try await picker.pick(
            candidates: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
            fallback: Locale(identifier: "en_US")
        )
        #expect(await calls.recorded.count == 4)
        #expect(pick.locale.identifier == "it_IT")
        #expect(pick.detection == .detected("it"))
    }

    @Test("windows are probed a round at a time and no probe is ever cancelled")
    func pickerProbesWholeRounds() async throws {
        let calls = Counter()
        let cancelled = Counter()
        let picker = AutoLanguagePicker(windowCount: 6, concurrentProbes: 4) { locale, window in
            await calls.record("\(window) \(locale.identifier)")
            for _ in 0..<5 { await Task.yield() }
            if Task.isCancelled { await cancelled.record(locale.identifier) }
            return locale.identifier == "it_IT" ? Self.speech : Self.mumble
        }
        let pick = try await picker.pick(
            candidates: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
            fallback: Locale(identifier: "en_US")
        )
        #expect(await Set(calls.recorded) == ["0 en_US", "0 it_IT", "1 en_US", "1 it_IT"])
        #expect(await cancelled.recorded.isEmpty)
        #expect(pick.detection == .detected("it"))
    }

    @Test("a window with nothing in it does not count toward agreement")
    func pickerReadsPastSilentWindows() async throws {
        let calls = Counter()
        let picker = AutoLanguagePicker(windowCount: 6, concurrentProbes: 1) { locale, window in
            await calls.record("\(window) \(locale.identifier)")
            guard window > 0 else { return LanguageProbeOutcome(text: "") }
            return locale.identifier == "it_IT" ? Self.speech : Self.mumble
        }
        let pick = try await picker.pick(
            candidates: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
            fallback: Locale(identifier: "en_US")
        )
        #expect(await calls.recorded.count == 6)
        #expect(pick.detection == .detected("it"))
    }

    @Test("windows that never agree are all heard and judged together")
    func pickerPoolsEveryWindowWithoutAgreement() async throws {
        let calls = Counter()
        let picker = AutoLanguagePicker(windowCount: 4, concurrentProbes: 1) { locale, window in
            await calls.record("\(window) \(locale.identifier)")
            switch (window, locale.identifier) {
            case (0, "it_IT"), (1, "en_US"): return Self.speech
            case (0, _), (1, _): return LanguageProbeOutcome(text: Self.words(30), confidence: 0.4, confidenceWeight: 10)
            default: return LanguageProbeOutcome(text: "")
            }
        }
        let pick = try await picker.pick(
            candidates: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
            fallback: Locale(identifier: "en_US")
        )
        #expect(await calls.recorded.count == 8)
        #expect(pick.detection == .assumed("en"), "an even pool is a coin toss, so it stays assumed")
    }

    @Test("the picker never runs more probes at once than its bound")
    func pickerBoundsConcurrency() async throws {
        let gauge = Gauge()
        let picker = AutoLanguagePicker(windowCount: 6, concurrentProbes: 3) { _, _ in
            await gauge.enter()
            for _ in 0..<5 { await Task.yield() }
            await gauge.leave()
            return LanguageProbeOutcome(text: "")
        }
        _ = try await picker.pick(
            candidates: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
            fallback: Locale(identifier: "en_US")
        )
        #expect(await gauge.entered == 12)
        #expect(await gauge.peak <= 3)
    }

    @Test("picker propagates cancellation instead of scoring a half-finished set")
    func pickerPropagatesCancellation() async {
        let picker = AutoLanguagePicker(windowCount: 2) { _, _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await picker.pick(
                candidates: [Locale(identifier: "en_US"), Locale(identifier: "it_IT")],
                fallback: Locale(identifier: "en_US")
            )
        }
    }

    @Test("windows agree when two of them pick the same language on their own")
    func windowsAgree() {
        let italian = [probe("en_US", words: 30, confidence: 0.3), probe("it_IT", words: 30, confidence: 0.95)]
        let english = [probe("en_US", words: 30, confidence: 0.95), probe("it_IT", words: 30, confidence: 0.3)]
        let thin = [probe("en_US", words: 0, confidence: nil), probe("it_IT", words: 3, confidence: 0.95)]
        let fallback = Locale(identifier: "en_US")

        #expect(AutoLanguage.windowsAgree([italian, italian], fallback: fallback))
        #expect(AutoLanguage.windowsAgree([english, italian, italian], fallback: fallback))
        #expect(!AutoLanguage.windowsAgree([english, italian], fallback: fallback))
        #expect(!AutoLanguage.windowsAgree([thin, italian], fallback: fallback), "a thin window is only an assumption")
        #expect(!AutoLanguage.windowsAgree([italian], fallback: fallback))
    }

    @Test("pooled outcomes weigh each window's confidence by how much it heard")
    func pooledOutcome() {
        let pooled = LanguageProbeOutcome.pooled([
            LanguageProbeOutcome(text: "uno due", confidence: 0.9, confidenceWeight: 10),
            LanguageProbeOutcome(text: "", confidence: nil, confidenceWeight: 0),
            LanguageProbeOutcome(text: "tre", confidence: 0.5, confidenceWeight: 30),
        ])
        #expect(pooled.text == "uno due tre")
        #expect(abs((pooled.confidence ?? 0) - 0.6) < 1e-9)
        #expect(pooled.confidenceWeight == 40)

        let silent = LanguageProbeOutcome.pooled([LanguageProbeOutcome(text: ""), LanguageProbeOutcome(text: "")])
        #expect(silent.text.isEmpty)
        #expect(silent.confidence == nil)
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
        let url = try Self.writeTone(sampleRate: 8000, seconds: 60, loudRange: 30..<40)
        defer { try? FileManager.default.removeItem(at: url) }
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let windows = try ProbeAudioExtractor.extractWindows(
            from: url,
            into: directory,
            windowSeconds: 10,
            windowLimit: 1,
            candidateLimit: 6
        )

        #expect(windows.count == 1)
        let written = try Self.read(try #require(windows.first))
        #expect(abs(written.seconds - 10) < 0.2)
        #expect(written.rms > 0.4, "the copy is the toned stretch, not the silence around it")
    }

    @Test("probe windows reach speech that starts long after the opening minutes")
    func extractionReachesLateSpeech() throws {
        let url = try Self.writeTone(sampleRate: 8000, seconds: 500, loudRange: 400..<500)
        defer { try? FileManager.default.removeItem(at: url) }
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let windows = try ProbeAudioExtractor.extractWindows(from: url, into: directory)

        #expect(!windows.isEmpty)
        let written = try windows.map(Self.read)
        #expect(written.allSatisfy { $0.rms > 0.2 })
        #expect(written.reduce(0) { $0 + $1.seconds } <= 120)
    }

    @Test("windows come out loudest first, each in a file of its own")
    func extractionOrdersByLoudness() throws {
        let url = try Self.writeTone(
            sampleRate: 8000, seconds: 100, loudRange: 0..<100, amplitude: { time in
                switch time {
                case 20..<40: 0.2
                case 60..<80: 0.8
                default: 0.01
                }
            }
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let windows = try ProbeAudioExtractor.extractWindows(
            from: url, into: directory, windowSeconds: 20, windowLimit: 2, candidateLimit: 5
        )

        let loudness = try windows.map { try Self.read($0).rms }
        #expect(loudness.count == 2)
        #expect(loudness == loudness.sorted(by: >))
        #expect(Set(windows).count == 2)
    }

    @Test("energies measured in memory match the same audio measured on disk")
    func memoryEnergiesMatchDisk() throws {
        let url = try Self.writeTone(sampleRate: 16_000, seconds: 120, loudRange: 40..<80)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

        let onDisk = try ProbeAudioExtractor.measure(AVAudioFile(forReading: url))
        let inMemory = ProbeAudioExtractor.measure(samples: samples, sampleRate: 16_000)

        #expect(onDisk.map(\.window) == inMemory.map(\.window))
        for (disk, memory) in zip(onDisk, inMemory) {
            #expect(abs(disk.energy - memory.energy) < 1e-4)
        }
        #expect(ProbeWindowPlanner.pick(from: onDisk) == ProbeWindowPlanner.pick(from: inMemory))
    }

    @Test("the Whisper probe reads samples from past the first five minutes")
    func whisperProbeSamplesReachLateSpeech() {
        let samples = Self.samples(seconds: 500, loudRange: 400..<500)

        let probe = Self.whisperProbe(samples)

        let offsets = WhisperKitTranscriber.probeWindowOffsets(in: probe, windowSamples: Self.whisperWindow)
        #expect(offsets.count == 3)
        #expect(offsets.allSatisfy { Self.loudness(of: probe, at: $0) > 0.2 })
    }

    @Test("a recording too short to tile twice is still read as two windows")
    func shortRecordingIsReadTwice() {
        let probe = Self.whisperProbe(Self.samples(seconds: 45, loudRange: 0..<45))

        let offsets = WhisperKitTranscriber.probeWindowOffsets(in: probe, windowSamples: Self.whisperWindow)
        #expect(offsets.count == 2)
        #expect(offsets.allSatisfy { Self.loudness(of: probe, at: $0) > 0.2 })
    }

    @Test("a recording shorter than one window is read once, all the way to its end")
    func veryShortRecordingIsReadOnce() {
        let probe = Self.whisperProbe(Self.samples(seconds: 25, loudRange: 0..<25))

        #expect(probe.count > 24 * 16_000, "the probe used to stop at the first 20 seconds")
        #expect(WhisperKitTranscriber.probeWindowOffsets(in: probe, windowSamples: Self.whisperWindow) == [0])
    }

    @Test("a 30-second recording whose speech starts late is probed on that speech")
    func lateSpeechInAShortRecordingIsHeard() {
        let probe = Self.whisperProbe(Self.samples(seconds: 30, loudRange: 22..<30))

        #expect(probe.count > 29 * 16_000)
        let offsets = WhisperKitTranscriber.probeWindowOffsets(in: probe, windowSamples: Self.whisperWindow)
        #expect(offsets == [0])
        #expect(Self.loudness(of: probe, at: 0) > 0.2)
    }

    @Test("a stereo source with sound on one side only is extracted as audible mono")
    func extractionDownmixesStereo() throws {
        let url = try Self.writeTone(sampleRate: 8000, seconds: 6, loudRange: 0..<6, channels: 2, loudChannel: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let windows = try ProbeAudioExtractor.extractWindows(
            from: url,
            into: directory,
            windowSeconds: 10,
            windowLimit: 1,
            candidateLimit: 4
        )

        #expect(windows.count == 1)
        let written = try AVAudioFile(forReading: try #require(windows.first))
        #expect(written.processingFormat.channelCount == 1)
        #expect(abs(Double(written.length) / written.processingFormat.sampleRate - 6) < 0.01)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: written.processingFormat, frameCapacity: AVAudioFrameCount(written.length))
        )
        try written.read(into: buffer)
        let peak = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
        #expect(peak > 0.2)
    }

    private static let whisperWindow = 30 * 16_000

    private static func whisperProbe(_ samples: [Float]) -> [Float] {
        WhisperKitTranscriber.probeSamples(
            from: samples,
            energies: ProbeAudioExtractor.measure(samples: samples, sampleRate: 16_000),
            sampleRate: 16_000
        )
    }

    /// A square wave at 0.8 inside `loudRange`, digital silence outside it, at 16 kHz.
    private static func samples(seconds: Double, loudRange: Range<Double>) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * 16_000))
        let loud = Int(loudRange.lowerBound * 16_000)..<min(samples.count, Int(loudRange.upperBound * 16_000))
        for index in loud { samples[index] = index.isMultiple(of: 2) ? 0.8 : -0.8 }
        return samples
    }

    private static func loudness(of samples: [Float], at offset: Int) -> Float {
        let window = samples[offset..<min(samples.count, offset + whisperWindow)]
        return (window.reduce(Float(0)) { $0 + $1 * $1 } / Float(window.count)).squareRoot()
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-probe-windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func read(_ url: URL) throws -> (seconds: Double, rms: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let rms = (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))).squareRoot()
        return (Double(file.length) / file.processingFormat.sampleRate, rms)
    }

    private func probe(_ identifier: String, words: Int, confidence: Double?) -> LanguageProbe {
        LanguageProbe(
            locale: Locale(identifier: identifier),
            outcome: LanguageProbeOutcome(text: Self.words(words), confidence: confidence)
        )
    }

    private static func words(_ count: Int) -> String {
        (0..<count).map { "w\($0)" }.joined(separator: " ")
    }

    private static let speech = LanguageProbeOutcome(text: words(30), confidence: 0.95, confidenceWeight: 10)
    private static let mumble = LanguageProbeOutcome(text: "uh uh uh uh uh uh", confidence: 0.3, confidenceWeight: 10)

    private static func writeTone(
        sampleRate: Double,
        seconds: Double,
        loudRange: Range<Double>,
        channels: AVAudioChannelCount = 1,
        loudChannel: Int? = nil,
        amplitude: (Double) -> Float = { _ in 0.8 }
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
                samples[frame] = loud ? Float(sin(2 * .pi * 440 * time)) * amplitude(time) : 0
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

private actor Gauge {
    private(set) var entered = 0
    private(set) var peak = 0
    private var inFlight = 0

    func enter() {
        entered += 1
        inFlight += 1
        peak = max(peak, inFlight)
    }

    func leave() { inFlight -= 1 }
}
