import Foundation
import Testing
@testable import Parola
import ParolaCore

/// A clock whose `sleep` returns at once, so a scheduled recording auto-stop fires without
/// the real minute-long wait. Only safe on capture paths that have no unbounded `while … sleep`
/// loop (the non-streaming mic path doesn't start the silence watch).
private struct ImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// Hand-builds a silent 16 kHz mono PCM16 WAV. Avoids `AVAudioFile.write`, whose CoreAudio
/// converter trips an assertion in the xctest host; the bytes here are a canonical WAV any
/// reader (incl. `FixtureAudioSource`) decodes.
private func makeSilentWAV(seconds: Double = 0.3) throws -> URL {
    let sampleRate = 16_000, channels = 1, bytesPerSample = 2
    let frames = Int(Double(sampleRate) * seconds)
    let dataBytes = frames * channels * bytesPerSample
    var data = Data()
    func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
    ascii("fmt "); le32(16); le16(1); le16(UInt16(channels))
    le32(UInt32(sampleRate)); le32(UInt32(sampleRate * channels * bytesPerSample))
    le16(UInt16(channels * bytesPerSample)); le16(UInt16(bytesPerSample * 8))
    ascii("data"); le32(UInt32(dataBytes))
    data.append(Data(count: dataBytes))
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("parola-recopt-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

@MainActor
private func makeRecordingModel(clock: any Clock<Duration> = ContinuousClock()) -> AppModel {
    let bootstrap = AppBootstrap(
        mode: .test,
        library: makeTempLibraryURL("recopt"),
        defaultsOverride: UserDefaults(suiteName: "test-\(UUID())")!,
        sideEffects: [],
        filePicker: TestFilePicker(),
        clock: clock
    )
    return AppModel(bootstrap: bootstrap)
}

@MainActor
@Suite("Recording media-session config")
struct RecordingMediaSessionConfigTests {
    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: UserDefaults(suiteName: "test-\(UUID())")!, libraryURL: makeTempLibraryURL("mediacfg"))
    }

    @Test("auto-mute mutes only when the source is the microphone")
    func muteGatedByMicSource() {
        let model = makeModel()
        model.autoMuteWhileRecording = true

        #expect(model.mediaSessionConfig(allowMute: true).muteSystemAudio == true)
        #expect(model.mediaSessionConfig(allowMute: false).muteSystemAudio == false)
    }

    @Test("auto-mute off never mutes")
    func muteOffNeverMutes() {
        let model = makeModel()
        model.autoMuteWhileRecording = false

        #expect(model.mediaSessionConfig(allowMute: true).muteSystemAudio == false)
        #expect(model.mediaSessionConfig(allowMute: false).muteSystemAudio == false)
    }

    @Test("auto-pause-media drives pausePlayback regardless of source")
    func pauseIndependentOfSource() {
        let model = makeModel()
        model.autoPauseMediaWhileRecording = true

        #expect(model.mediaSessionConfig(allowMute: true).pausePlayback == true)
        #expect(model.mediaSessionConfig(allowMute: false).pausePlayback == true)

        model.autoPauseMediaWhileRecording = false
        #expect(model.mediaSessionConfig(allowMute: true).pausePlayback == false)
    }

    @Test("both toggles off yields an inert config")
    func bothOffIsInert() {
        let model = makeModel()
        model.autoMuteWhileRecording = false
        model.autoPauseMediaWhileRecording = false

        #expect(model.mediaSessionConfig(allowMute: true) == MediaSessionConfig(muteSystemAudio: false, pausePlayback: false))
    }
}

@MainActor
@Suite("Recording count-in", .serialized)
struct RecordingCountInTests {
    @Test("a positive count-in shows the countdown and defers capture")
    func positiveCountInDefersCapture() async throws {
        let fixture = try makeSilentWAV()
        await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
        defer { Task { await MockAudioSourceRegistry.shared.clear() } }

        let model = makeRecordingModel()
        model.useStreaming = false
        model.recordingCountInSeconds = 3

        model.startRecording(source: .microphone)
        #expect(model.recordingCountdown == 3)

        model.cancelRecordingCountdown()
        #expect(model.recordingCountdown == nil)
    }

    @Test("a zero count-in shows no countdown")
    func zeroCountInNoCountdown() async throws {
        let fixture = try makeSilentWAV()
        await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
        defer { Task { await MockAudioSourceRegistry.shared.clear() } }

        let model = makeRecordingModel()
        model.useStreaming = false
        model.recordingCountInSeconds = 0

        model.startRecording(source: .microphone)
        #expect(model.recordingCountdown == nil)

        model.cancelCurrentWork()
    }

    @Test("a negative count-in is clamped to zero")
    func negativeCountInClamped() async throws {
        let fixture = try makeSilentWAV()
        await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
        defer { Task { await MockAudioSourceRegistry.shared.clear() } }

        let model = makeRecordingModel()
        model.useStreaming = false
        model.recordingCountInSeconds = -5

        model.startRecording(source: .microphone)
        #expect(model.recordingCountdown == nil)

        model.cancelCurrentWork()
    }
}

@MainActor
@Suite("Recording auto-stop", .serialized)
struct RecordingAutoStopTests {
    private func waitUntil(timeoutMs: Int = 3000, _ condition: @MainActor () -> Bool) async -> Bool {
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
            elapsed += 15
        }
        return condition()
    }

    private func isRecording(_ model: AppModel) -> Bool {
        if case .recording = model.phase { return true }
        return false
    }

    @Test("a positive max-minutes auto-stops the recording on its own")
    func autoStopFires() async throws {
        let fixture = try makeSilentWAV()
        await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
        // A failing mock routes the auto-stop's stop→transcribe into the catch (.failed) so the
        // run never persists to the library (CoreSpotlight indexing hangs the xctest host).
        await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
            failure: MockTranscriberFailure(code: .transcriptionFailed, message: "auto-stop fired")
        ))
        defer {
            Task {
                await MockAudioSourceRegistry.shared.clear()
                await MockTranscriberRegistry.shared.clear()
            }
        }

        let model = makeRecordingModel(clock: ImmediateClock())
        model.useStreaming = false
        model.selectedModel = "openai_whisper-tiny"
        model.recordingCountInSeconds = 0
        model.recordingMaxMinutes = 1

        model.startRecording(source: .microphone)

        let stopped = await waitUntil {
            if case .failed = model.phase { return true }
            return false
        }
        #expect(stopped)
        #expect(!isRecording(model))
    }

    @Test("a zero max-minutes leaves the recording running")
    func zeroMaxMinutesNeverStops() async throws {
        let fixture = try makeSilentWAV()
        await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
        defer { Task { await MockAudioSourceRegistry.shared.clear() } }

        let model = makeRecordingModel(clock: ImmediateClock())
        model.useStreaming = false
        model.recordingCountInSeconds = 0
        model.recordingMaxMinutes = 0

        model.startRecording(source: .microphone)

        let started = await waitUntil { self.isRecording(model) }
        #expect(started)

        try? await Task.sleep(for: .milliseconds(300))
        #expect(isRecording(model))

        model.cancelCurrentWork()
    }
}
