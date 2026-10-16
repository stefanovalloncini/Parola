import AppKit
import AVFAudio
import Foundation
import ParolaCore
import ParolaSpeech

/// Keeps the Mac from idle-sleeping while a reading generates or plays; the display may still turn off.
struct ReadAloudActivity {
    var begin: @MainActor () -> any NSObjectProtocol
    var end: @MainActor (any NSObjectProtocol) -> Void

    static let inert = ReadAloudActivity(begin: { NSObject() }, end: { _ in })

    static let processInfo = ReadAloudActivity(
        begin: { ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Reading aloud") },
        end: { ProcessInfo.processInfo.endActivity($0) }
    )
}

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
    var appleVoices: @MainActor () -> AppleVoiceInventory = { AppleVoiceInventory() }
    var previewRenderer: (@MainActor () -> any SpeechRenderer)?
    var personalVoiceStatus: @MainActor () -> PersonalVoiceStatus = { .unsupported }
    var requestPersonalVoice: @MainActor () async -> PersonalVoiceStatus = { .unsupported }
    var openURL: @MainActor (URL) -> Bool = { _ in false }
    var activity: ReadAloudActivity = .inert

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
            mockVoice: nil,
            appleVoices: { system.inventory() },
            previewRenderer: { system.previewRenderer() },
            personalVoiceStatus: { PersonalVoiceStatus(AVSpeechSynthesizer.personalVoiceAuthorizationStatus) },
            requestPersonalVoice: { PersonalVoiceStatus(await AVSpeechSynthesizer.requestPersonalVoiceAuthorization()) },
            openURL: { NSWorkspace.shared.open($0) },
            activity: .processInfo
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
            mockVoice: voice,
            appleVoices: { voice.inventory },
            previewRenderer: { voice.makeRenderer() },
            personalVoiceStatus: { voice.personalVoiceStatus },
            requestPersonalVoice: { voice.personalVoiceStatus },
            openURL: { voice.record($0) }
        )
    }
}

@MainActor
final class LiveReadAloudSystem {
    private var apple: AppleSpeechRenderer?
    private var output: ReadAloudOutput?
    private let voices = StaleVoiceInventory()

    func renderer() -> any SpeechRenderer {
        if let apple {
            voices.refreshIfStale(apple.refreshVoices)
            return apple
        }
        let made = AppleSpeechRenderer()
        apple = made
        voices.markFresh()
        return made
    }

    func inventory() -> AppleVoiceInventory {
        guard let renderer = renderer() as? AppleSpeechRenderer else { return AppleVoiceInventory() }
        return AppleVoiceInventory(voices: renderer.knownVoices, unusable: renderer.unusableIdentifiers)
    }

    func previewRenderer() -> any SpeechRenderer {
        guard let main = renderer() as? AppleSpeechRenderer else { return AppleSpeechRenderer() }
        return AppleSpeechRenderer(inventory: main.knownVoices, unusable: main.unusableIdentifiers)
    }

    func sink() throws -> any ReadAloudOutputSink {
        if let output { return output }
        let made = try ReadAloudOutput()
        output = made
        return made
    }

    func refreshVoices() {
        voices.markStale()
    }
}

extension PersonalVoiceStatus {
    init(_ status: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .notDetermined: self = .notDetermined
        case .unsupported: self = .unsupported
        @unknown default: self = .unsupported
        }
    }
}

/// Reading the installed voices costs about 170 ms on main, so a change only marks the list stale and the next Read re-reads it.
@MainActor
final class StaleVoiceInventory {
    private var isStale = false

    func markStale() {
        isStale = true
    }

    func markFresh() {
        isStale = false
    }

    func refreshIfStale(_ refresh: () -> Void) {
        guard isStale else { return }
        isStale = false
        refresh()
    }
}

/// The silent voice a sandbox or a test reads with: a unit lasts `msPerUnit`; a language outside `languages` has no voice.
@MainActor
final class MockVoiceSettings {
    static let defaultMsPerUnit = 300
    static let defaultLanguages: Set<String> = ["en", "it", "fr", "de", "es", "pt", "nl", "ja", "zh"]

    private(set) var msPerUnit = MockVoiceSettings.defaultMsPerUnit
    private(set) var failAtUnit: Int?
    private(set) var isInstalled = false
    private(set) var openedURLs: [URL] = []
    var languages = MockVoiceSettings.defaultLanguages
    var personalVoiceStatus = PersonalVoiceStatus.notDetermined
    var unusableVoices: Set<String> = []

    var inventory: AppleVoiceInventory {
        let voices = languages.sorted().flatMap { language in
            [
                VoiceDescriptor(
                    identifier: "com.parola.mock.\(language).premium", name: "Mock Premium", language: language,
                    quality: .premium, isNovelty: false, isPersonal: false, family: .standard
                ),
                VoiceDescriptor(
                    identifier: "com.parola.mock.\(language).compact", name: "Mock Compact", language: language,
                    quality: .default, isNovelty: false, isPersonal: false, family: .standard
                ),
            ]
        }
        return AppleVoiceInventory(voices: voices, unusable: unusableVoices)
    }

    func record(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }

    func install(msPerUnit: Int, failAtUnit: Int?) {
        self.msPerUnit = max(1, msPerUnit)
        self.failAtUnit = failAtUnit
        isInstalled = true
    }

    func clear() {
        msPerUnit = Self.defaultMsPerUnit
        failAtUnit = nil
        isInstalled = false
        languages = Self.defaultLanguages
        unusableVoices = []
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

/// An offline output that renders itself in real time while it plays, so a sandbox reading advances with no audio device.
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
