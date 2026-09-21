import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

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
        defaultsOverride: temporaryDefaults(),
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
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("mediacfg"))
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

    @Test("auto-pause-media drives pausePlayback in mic-style configs")
    func pauseFollowsToggle() {
        let model = makeModel()
        model.autoPauseMediaWhileRecording = true

        #expect(model.mediaSessionConfig(allowMute: true).pausePlayback == true)

        model.autoPauseMediaWhileRecording = false
        #expect(model.mediaSessionConfig(allowMute: true).pausePlayback == false)
    }

    @Test("system-audio recordings never pause or mute the media they capture")
    func systemAudioLeavesMediaAlone() {
        let model = makeModel()
        model.autoPauseMediaWhileRecording = true
        model.autoMuteWhileRecording = true

        #expect(model.recordingMediaConfig(for: .systemAudio) == .none)
        #expect(model.recordingMediaConfig(for: .microphone).pausePlayback == true)
        #expect(model.recordingMediaConfig(for: .microphone).muteSystemAudio == true)
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
        try await withMocksCleared(.audioSource) {
            let fixture = try makeSilentWAV()
            await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)

            let model = makeRecordingModel()
            model.useStreaming = false
            model.recordingCountInSeconds = 3

            model.startRecording(source: .microphone)
            #expect(model.recordingCountdown == 3)

            model.cancelRecordingCountdown()
            #expect(model.recordingCountdown == nil)
        }
    }

    @Test("a zero count-in shows no countdown")
    func zeroCountInNoCountdown() async throws {
        try await withMocksCleared(.audioSource) {
            let fixture = try makeSilentWAV()
            await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)

            let model = makeRecordingModel()
            model.useStreaming = false
            model.recordingCountInSeconds = 0

            model.startRecording(source: .microphone)
            #expect(model.recordingCountdown == nil)

            model.cancelCurrentWork()
        }
    }

    @Test("a negative count-in is clamped to zero")
    func negativeCountInClamped() async throws {
        try await withMocksCleared(.audioSource) {
            let fixture = try makeSilentWAV()
            await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)

            let model = makeRecordingModel()
            model.useStreaming = false
            model.recordingCountInSeconds = -5

            model.startRecording(source: .microphone)
            #expect(model.recordingCountdown == nil)

            model.cancelCurrentWork()
        }
    }
}

extension TranscriberMockSuites {
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
            try await withMocksCleared([.audioSource, .transcriber]) {
                let fixture = try makeSilentWAV()
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                // A failing mock routes the auto-stop's stop→transcribe into the catch (.failed) so the
                // run never persists to the library (CoreSpotlight indexing hangs the xctest host).
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "auto-stop fired")
                ))

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
        }

        @Test("a zero max-minutes leaves the recording running")
        func zeroMaxMinutesNeverStops() async throws {
            try await withMocksCleared(.audioSource) {
                let fixture = try makeSilentWAV()
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)

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
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Recording stop during startup", .serialized)
    struct RecordingStartupStopTests {
        private func waitUntil(timeoutMs: Int = 5000, _ condition: @MainActor () -> Bool) async -> Bool {
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

        @Test("a stop that lands while the capture is still starting discards the take")
        func stopDuringStartupWins() async throws {
            try await withMocksCleared(.audioSource) {
                let fixture = try makeSilentWAV()
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)

                let model = makeRecordingModel()
                model.useStreaming = false
                model.selectedModel = "openai_whisper-tiny"
                model.recordingCountInSeconds = 0

                model.startRecording(source: .microphone)
                #expect(model.recordingActive)
                #expect(model.liveSource == nil, "the capture has not landed yet")

                model.stopRecordingAndTranscribe()

                let settled = await waitUntil { !model.recordingActive }
                #expect(settled, "the stop must not be swallowed by the startup window")
                #expect(model.liveSource == nil)
                #expect(model.phase == .idle)
                #expect(model.transcript == nil)
            }
        }

        @Test("a stop during startup leaves the next recording free to start")
        func stopDuringStartupDoesNotLatch() async throws {
            try await withMocksCleared(.audioSource) {
                let fixture = try makeSilentWAV()
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)

                let model = makeRecordingModel()
                model.useStreaming = false
                model.selectedModel = "openai_whisper-tiny"
                model.recordingCountInSeconds = 0

                model.startRecording(source: .microphone)
                model.stopRecordingAndTranscribe()
                let settled = await waitUntil { !model.recordingActive }
                #expect(settled)
                #expect(model.liveSource == nil)

                model.startRecording(source: .microphone)
                let restarted = await waitUntil { self.isRecording(model) && model.liveSource != nil }
                #expect(restarted, "the discarded take must not latch the recording state")

                model.cancelCurrentWork()
            }
        }

        @Test("a stop held for startup resolves its waiter as cancelled", .timeLimit(.minutes(1)))
        func stopHeldForStartupResolvesWaiter() async throws {
            try await withMocksCleared(.audioSource) {
                let fixture = try makeSilentWAV()
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)

                let model = makeRecordingModel()
                model.useStreaming = false
                model.selectedModel = "openai_whisper-tiny"
                model.recordingCountInSeconds = 0

                model.startRecording(source: .microphone)
                model.stopRecordingAndTranscribe()
                #expect(
                    model.stopHeldForStartup,
                    "a stop intent has to wait for the take instead of reporting nothing recording"
                )

                await #expect(throws: IntentActionError.cancelled) {
                    _ = try await model.awaitRecordingOutcome()
                }
            }
        }

        @Test("a stop during startup also discards a streaming take")
        func stopDuringStartupWinsOnTheStreamingPath() async throws {
            await MockAudioSourceRegistry.shared.clear()
            MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["never"]))
            defer { MockStreamingTranscriberRegistry.shared.clear() }

            let model = makeRecordingModel()
            model.useStreaming = true
            model.selectedModel = "openai_whisper-tiny"
            model.recordingCountInSeconds = 0
            #expect(await model.shouldUseStreamingMic(), "this test only covers the streaming branch")

            model.startRecording(source: .microphone)
            #expect(model.recordingActive)

            model.stopRecordingAndTranscribe()

            let settled = await waitUntil { !model.recordingActive }
            #expect(settled, "the stop must not be swallowed by the streaming startup window")
            #expect(model.streamingConsumer == nil, "the streaming session must never come up after a stop")
            #expect(model.phase == .idle)
            #expect(model.transcript == nil)
        }
    }
}
