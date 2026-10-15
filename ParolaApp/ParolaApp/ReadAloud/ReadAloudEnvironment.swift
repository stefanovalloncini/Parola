import AppKit
import AVFAudio
import Foundation
import ParolaCore
import ParolaSpeech

/// Everything the controller reaches outside itself, so a test or a sandbox swaps the sound for silence.
@MainActor
struct ReadAloudEnvironment {
    var renderer: @MainActor () -> any SpeechRenderer
    var sink: @MainActor () throws -> any ReadAloudOutputSink
    var nowPlaying: @MainActor () -> any NowPlayingPublishing
    var refreshVoices: @MainActor () -> Void
    var systemNotifications: @MainActor () -> NotificationCenter
    var appNotifications: NotificationCenter
    var clock: any Clock<Duration>
    var mockVoice: MockVoiceSettings?

    static func make(for bootstrap: AppBootstrap) -> ReadAloudEnvironment {
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if bootstrap.mode == .normal, bootstrap.sideEffects.contains(.readAloudSystem), !underTest {
            return live()
        }
        return silent()
    }

    static func live() -> ReadAloudEnvironment {
        let system = LiveReadAloudSystem()
        return ReadAloudEnvironment(
            renderer: { system.renderer() },
            sink: { try system.sink() },
            nowPlaying: { ReadAloudNowPlaying() },
            refreshVoices: { system.refreshVoices() },
            systemNotifications: { NSWorkspace.shared.notificationCenter },
            appNotifications: .default,
            clock: ContinuousClock(),
            mockVoice: nil
        )
    }

    static func silent(
        voice: MockVoiceSettings = MockVoiceSettings(),
        systemNotifications: NotificationCenter = NotificationCenter(),
        appNotifications: NotificationCenter = NotificationCenter(),
        clock: any Clock<Duration> = ContinuousClock()
    ) -> ReadAloudEnvironment {
        ReadAloudEnvironment(
            renderer: { voice.makeRenderer() },
            sink: { PumpedOfflineSink(output: try ReadAloudOutput(offline: true, monitor: nil), clock: clock) },
            nowPlaying: { RecordingNowPlaying() },
            refreshVoices: {},
            systemNotifications: { systemNotifications },
            appNotifications: appNotifications,
            clock: clock,
            mockVoice: voice
        )
    }
}

@MainActor
final class LiveReadAloudSystem {
    private var apple: AppleSpeechRenderer?
    private var output: ReadAloudOutput?

    func renderer() -> any SpeechRenderer {
        if let apple { return apple }
        let made = AppleSpeechRenderer()
        apple = made
        return made
    }

    func sink() throws -> any ReadAloudOutputSink {
        if let output { return output }
        let made = try ReadAloudOutput()
        output = made
        return made
    }

    func refreshVoices() {
        apple?.refreshVoices()
    }
}

/// The silent voice a sandbox or a test reads with: every unit lasts `msPerUnit`, and a language outside
/// `languages` has no voice.
@MainActor
final class MockVoiceSettings {
    static let defaultMsPerUnit = 300
    static let defaultLanguages: Set<String> = ["en", "it", "fr", "de", "es", "pt", "nl", "ja", "zh"]

    private(set) var msPerUnit = MockVoiceSettings.defaultMsPerUnit
    private(set) var failAtUnit: Int?
    private(set) var isInstalled = false
    var languages = MockVoiceSettings.defaultLanguages

    func install(msPerUnit: Int, failAtUnit: Int?) {
        self.msPerUnit = max(1, msPerUnit)
        self.failAtUnit = failAtUnit
        isInstalled = true
    }

    func clear() {
        msPerUnit = Self.defaultMsPerUnit
        failAtUnit = nil
        isInstalled = false
    }

    func makeRenderer() -> any SpeechRenderer {
        MockSpeechRenderer(
            capabilities: SpeechRendererCapabilities(
                languages: languages, expandsNumbers: true, usesNeuralEngine: false, nominalRTF: 0, maxUnitChars: 400
            ),
            secondsPerUnit: Double(msPerUnit) / 1000,
            failAtUnit: failAtUnit
        )
    }
}

/// An offline output that renders on its own in real time while it plays, so a sandbox reading advances
/// unit by unit without opening an audio device.
@MainActor
final class PumpedOfflineSink: ReadAloudOutputSink {
    static let slice: AVAudioFrameCount = 2_400
    static let interval: Duration = .milliseconds(50)

    private let output: ReadAloudOutput
    private let clock: any Clock<Duration>
    private var pump: Task<Void, Never>?

    init(output: ReadAloudOutput, clock: any Clock<Duration>) {
        self.output = output
        self.clock = clock
    }

    deinit {
        pump?.cancel()
    }

    var speed: Double { output.speed }

    func setSpeed(_ speed: Double) {
        output.setSpeed(speed)
    }

    func unitFinishedEvents() -> AsyncStream<UnitFinished> {
        output.unitFinishedEvents()
    }

    func schedule(_ chunk: PCMChunk, epoch: Int, gainDB: Double) {
        output.schedule(chunk, epoch: epoch, gainDB: gainDB)
    }

    func finishUnit(_ unitID: Int, epoch: Int, pauseAfter: Double) {
        output.finishUnit(unitID, epoch: epoch, pauseAfter: pauseAfter)
    }

    func pause(fade: Bool) {
        output.pause(fade: false)
        stopPump()
    }

    func resume() throws {
        try output.resume()
        startPump()
    }

    func stop() {
        stopPump()
        output.stop()
    }

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self, clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: Self.interval)
                guard !Task.isCancelled, let self, self.output.state == .playing else { continue }
                _ = try? self.output.renderOffline(frames: Self.slice)
            }
        }
    }

    private func stopPump() {
        pump?.cancel()
        pump = nil
    }
}
