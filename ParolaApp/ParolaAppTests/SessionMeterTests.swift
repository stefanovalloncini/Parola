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

private struct CapsuleInSight: View {
    let take: RecordingSession
    let sight: Sight
    let reduceMotion: Bool

    var body: some View {
        SessionCapsuleFace(take: take, showsMeter: true, isOnScreen: sight.shown, showStage: {}, stop: { _ in })
            .environment(\._accessibilityReduceMotion, reduceMotion)
    }
}

@MainActor
@Suite("Session capsule meter out of sight", .serialized)
struct SessionMeterSightTests {
    private func meterValue(in hosted: HostedWindow) -> String? {
        let meter = HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix("Toolbar.Meter.SessionLevel") == true }
        return meter?.value
    }

    @Test(
        "while the window is covered the capsule's meter draws nothing new, and it catches up once the window shows",
        arguments: [false, true]
    )
    func meterRestsWhileCovered(reduceMotion: Bool) async throws {
        let audio = try tempWAV("capsule-meter-sight")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("capsule-meter-sight")
        model.useStreaming = false
        model.selectedModel = "openai_whisper-tiny"
        let capture = LevelCapture(file: audio)
        model.takeCaptureOverride = { _ in capture }
        defer { model.cancelCurrentWork() }
        model.startRecording(source: .microphone)
        let up = await waitUntil { model.liveSource != nil }
        try #require(up)
        capture.levelMeter.record(0.2)
        let recording = await waitUntil { model.recording?.state == .recording }
        try #require(recording)
        let take = try #require(model.recording)

        let sight = Sight()
        let hosted = HostedWindow(CapsuleInSight(take: take, sight: sight, reduceMotion: reduceMotion).environment(model), width: 400, height: 80)
        defer { hosted.close() }
        let drawn = await waitUntil { meterValue(in: hosted) != nil }
        try #require(drawn)
        let before = meterValue(in: hosted)

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
        let covered = meterValue(in: hosted)
        #expect(covered == before, "covered, the meter still shows \(covered ?? "nothing") from before the level rose")
        #expect(covered != AppFormat.percent(0.8))

        sight.shown = true
        let caughtUp = await waitUntil { meterValue(in: hosted) == AppFormat.percent(0.8) }
        #expect(caughtUp)
    }
}
