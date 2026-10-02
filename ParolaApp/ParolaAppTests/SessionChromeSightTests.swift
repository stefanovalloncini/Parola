import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore

/// A capture whose level the test sets.
private actor LevelCapture: LiveAudioSource {
    nonisolated let levelMeter = LevelMeter()
    private let file: URL

    init(file: URL) { self.file = file }

    func start() async throws {}
    func prepare() async throws -> URL { file }
    func cancel() async {}
}

@MainActor
@Observable
private final class Sight {
    var shown = false
}

/// The two surfaces outside the Stage that draw the take's level and time.
enum ChromeSurface: String, CaseIterable, Sendable {
    case capsule
    case pill

    var meter: String { self == .capsule ? "Toolbar.Meter.SessionLevel" : "RecordingPill.Meter.Level" }
    var clock: String { self == .capsule ? "Toolbar.Button.SessionTime" : "RecordingPill.Button.ShowParola" }
}

private struct ChromeInSight: View {
    let surface: ChromeSurface
    let take: RecordingSession
    let model: AppModel
    let sight: Sight
    let reduceMotion: Bool

    var body: some View {
        Group {
            switch surface {
            case .capsule:
                SessionCapsuleFace(take: take, showsMeter: true, isOnScreen: sight.shown, showStage: {}, stop: { _ in })
            case .pill:
                RecordingPillFace(model: model, isOnScreen: sight.shown, onShowParola: {}, onStop: { _ in }, onSize: { _ in })
            }
        }
        .environment(\._accessibilityReduceMotion, reduceMotion)
    }
}

@MainActor
@Suite("Session chrome out of sight", .serialized)
struct SessionChromeSightTests {
    private func element(_ suffix: String, in hosted: HostedWindow) -> HostedAccessibility.Element? {
        HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix(suffix) == true }
    }

    private func host(_ surface: ChromeSurface, _ take: RecordingSession, _ model: AppModel, _ sight: Sight, reduceMotion: Bool = false) -> HostedWindow {
        let content = ChromeInSight(surface: surface, take: take, model: model, sight: sight, reduceMotion: reduceMotion)
        return HostedWindow(content.environment(model), width: 400, height: 80)
    }

    @Test(
        "while its window is out of sight the capsule's or the pill's meter draws nothing new, and it catches up once the window shows",
        arguments: ChromeSurface.allCases, [false, true]
    )
    func meterRestsOutOfSight(surface: ChromeSurface, reduceMotion: Bool) async throws {
        let audio = try tempWAV("chrome-meter-sight")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("chrome-meter-sight")
        model.useStreaming = false
        model.selectedModel = "openai_whisper-tiny"
        let capture = LevelCapture(file: audio)
        model.takeCaptureOverride = { _ in capture }
        defer { Task { await model.discardTake() } }
        model.startRecording(source: .microphone)
        let up = await waitUntil { model.liveSource != nil }
        try #require(up)
        capture.levelMeter.record(0.2)
        let recording = await waitUntil { model.recording?.state == .recording }
        try #require(recording)
        let take = try #require(model.recording)

        let sight = Sight()
        let hosted = host(surface, take, model, sight, reduceMotion: reduceMotion)
        defer { hosted.close() }
        let drawn = await waitUntil { element(surface.meter, in: hosted)?.value != nil }
        try #require(drawn)
        let before = element(surface.meter, in: hosted)?.value

        let loud = Task { @MainActor in
            while !Task.isCancelled {
                capture.levelMeter.record(0.8)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { loud.cancel() }
        let heard = await waitUntil { model.takeLevels?.recent(1).first == 0.8 }
        try #require(heard)
        let tick = model.takeLevelTick
        let movedOn = await waitUntil { model.takeLevelTick >= tick + 3 }
        try #require(movedOn)
        let hidden = element(surface.meter, in: hosted)?.value
        #expect(hidden == before, "out of sight, the meter still shows \(hidden ?? "nothing") from before the level rose")
        #expect(hidden != AppFormat.percent(0.8))

        sight.shown = true
        let caughtUp = await waitUntil { element(surface.meter, in: hosted)?.value == AppFormat.percent(0.8) }
        #expect(caughtUp)
    }

    @Test("while its window is out of sight the capsule's or the pill's clock stands still, and it ticks again once the window shows", arguments: ChromeSurface.allCases)
    func clockRestsOutOfSight(surface: ChromeSurface) async throws {
        let audio = try tempWAV("chrome-clock-sight")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("chrome-clock-sight")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -30))
        defer { model.endTestTake() }
        let take = try #require(model.recording)

        let sight = Sight()
        let hosted = host(surface, take, model, sight)
        defer { hosted.close() }
        let drawn = await waitUntil { element(surface.clock, in: hosted)?.label != nil }
        try #require(drawn)
        let before = element(surface.clock, in: hosted)?.label

        await settle(for: .milliseconds(1_300))
        let hidden = element(surface.clock, in: hosted)?.label
        #expect(hidden == before, "out of sight, the clock still reads \(hidden ?? "nothing")")

        sight.shown = true
        let ticked = await waitUntil(timeoutMs: 3_000) { element(surface.clock, in: hosted)?.label != before }
        #expect(ticked)
    }
}
