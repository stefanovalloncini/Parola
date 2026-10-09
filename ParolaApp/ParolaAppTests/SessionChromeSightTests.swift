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
private func meterBars(in hosted: HostedWindow) -> LiveLevelBars.BarsView? {
    func views(in view: NSView) -> [LiveLevelBars.BarsView] {
        ((view as? LiveLevelBars.BarsView).map { [$0] } ?? []) + view.subviews.flatMap(views(in:))
    }
    hosted.host.layoutSubtreeIfNeeded()
    return views(in: hosted.host).first
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
        defer { await model.discardTake() }
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
        #expect(meterBars(in: hosted)?.levels.last != 0.8, "out of sight, the bars don't follow the take")

        sight.shown = true
        let caughtUp = await waitUntil { element(surface.meter, in: hosted)?.value == AppFormat.percent(0.8) }
        #expect(caughtUp)
        let barsCaughtUp = await waitUntil { meterBars(in: hosted)?.levels.last == 0.8 }
        #expect(barsCaughtUp)
    }

    @Test(
        "in sight, the capsule's bars follow the take on their own, and SwiftUI reads each level only for VoiceOver",
        arguments: [false, true], [false, true]
    )
    func capsuleBarsFollowTheTake(voiceOver: Bool, reduceMotion: Bool) async throws {
        try await barsFollowTheTake(.capsule, voiceOver: voiceOver, reduceMotion: reduceMotion)
    }

    @Test(
        "in sight, the pill's bars follow the take on their own, and SwiftUI reads each level only for VoiceOver",
        arguments: [false, true], [false, true]
    )
    func pillBarsFollowTheTake(voiceOver: Bool, reduceMotion: Bool) async throws {
        try await barsFollowTheTake(.pill, voiceOver: voiceOver, reduceMotion: reduceMotion)
    }

    private func barsFollowTheTake(_ surface: ChromeSurface, voiceOver: Bool, reduceMotion: Bool) async throws {
        let audio = try tempWAV("\(surface.rawValue)-bars-follow")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("\(surface.rawValue)-bars-follow")
        model.useStreaming = false
        model.selectedModel = "openai_whisper-tiny"
        model.voiceOverIsRunning = voiceOver
        let capture = LevelCapture(file: audio)
        model.takeCaptureOverride = { _ in capture }
        defer { await model.discardTake() }
        model.startRecording(source: .microphone)
        let up = await waitUntil { model.liveSource != nil }
        try #require(up)
        capture.levelMeter.record(0.2)
        let recording = await waitUntil { model.recording?.state == .recording }
        try #require(recording)
        let take = try #require(model.recording)

        let sight = Sight()
        sight.shown = true
        let hosted = host(surface, take, model, sight, reduceMotion: reduceMotion)
        defer { hosted.close() }
        let drawn = await waitUntil { element(surface.meter, in: hosted)?.value != nil && meterBars(in: hosted) != nil }
        try #require(drawn)
        let first = element(surface.meter, in: hosted)?.value
        let bars = try #require(meterBars(in: hosted))

        let loud = Task { @MainActor in
            while !Task.isCancelled {
                capture.levelMeter.record(0.8)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { loud.cancel() }
        let followed = await waitUntil { bars.levels.last == 0.8 }
        #expect(followed, "the bars keep up with the take")
        #expect(bars.bars.path != nil)

        if voiceOver {
            let spoken = await waitUntil { element(surface.meter, in: hosted)?.value == AppFormat.percent(0.8) }
            #expect(spoken, "VoiceOver hears the new level")
        } else {
            let tick = model.takeLevelTick
            let movedOn = await waitUntil { model.takeLevelTick >= tick + 3 }
            try #require(movedOn)
            let held = element(surface.meter, in: hosted)?.value
            #expect(held == first, "the stand-in followed a tick SwiftUI never reads: \(held ?? "nothing")")
        }
    }

    @Test(
        "with VoiceOver and Reduce Motion the capsule's or the pill's meter says the level as its bars step, four times a second, not with each sample",
        arguments: ChromeSurface.allCases
    )
    func spokenLevelKeepsTheBarsPace(surface: ChromeSurface) async throws {
        let audio = try tempWAV("\(surface.rawValue)-spoken-pace")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("\(surface.rawValue)-spoken-pace")
        model.useStreaming = false
        model.selectedModel = "openai_whisper-tiny"
        model.voiceOverIsRunning = true
        let capture = LevelCapture(file: audio)
        model.takeCaptureOverride = { _ in capture }
        defer { await model.discardTake() }
        model.startRecording(source: .microphone)
        let up = await waitUntil { model.liveSource != nil }
        try #require(up)
        capture.levelMeter.record(0.2)
        let recording = await waitUntil { model.recording?.state == .recording }
        try #require(recording)
        let take = try #require(model.recording)

        let sight = Sight()
        sight.shown = true
        let hosted = host(surface, take, model, sight, reduceMotion: true)
        defer { hosted.close() }
        let drawn = await waitUntil { element(surface.meter, in: hosted)?.value != nil }
        try #require(drawn)

        let climb = climbingLevels(on: capture.levelMeter)
        defer { climb.cancel() }
        let tick = model.takeLevelTick
        let said = await changes(of: { element(surface.meter, in: hosted)?.value }, over: .milliseconds(2_500))
        let samples = model.takeLevelTick - tick
        #expect(samples >= 15, "the take kept only \(samples) samples")
        #expect(said >= 3, "VoiceOver heard the level change \(said) times")
        #expect(said <= 17, "VoiceOver heard the level change \(said) times in 2.5 s, with each sample rather than each step")
    }

    @Test(
        "with VoiceOver and Reduce Motion the capsule's or the pill's bars step four times a second, and SwiftUI's updates add no steps of their own",
        arguments: ChromeSurface.allCases
    )
    func barsKeepTheirPaceUnderVoiceOver(surface: ChromeSurface) async throws {
        let audio = try tempWAV("\(surface.rawValue)-bars-pace")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("\(surface.rawValue)-bars-pace")
        model.useStreaming = false
        model.selectedModel = "openai_whisper-tiny"
        model.voiceOverIsRunning = true
        let capture = LevelCapture(file: audio)
        model.takeCaptureOverride = { _ in capture }
        defer { await model.discardTake() }
        model.startRecording(source: .microphone)
        let up = await waitUntil { model.liveSource != nil }
        try #require(up)
        capture.levelMeter.record(0.2)
        let recording = await waitUntil { model.recording?.state == .recording }
        try #require(recording)
        let take = try #require(model.recording)

        let sight = Sight()
        sight.shown = true
        let hosted = host(surface, take, model, sight, reduceMotion: true)
        defer { hosted.close() }
        let drawn = await waitUntil { meterBars(in: hosted) != nil }
        try #require(drawn)
        let bars = try #require(meterBars(in: hosted))

        let climb = climbingLevels(on: capture.levelMeter)
        defer { climb.cancel() }
        let tick = model.takeLevelTick
        let stepped = await changes(of: { bars.levels.description }, over: .milliseconds(4_000))
        let samples = model.takeLevelTick - tick
        #expect(samples >= 25, "the take kept only \(samples) samples")
        #expect(stepped >= 6, "the bars stepped \(stepped) times")
        #expect(stepped <= 20, "the bars stepped \(stepped) times in 4 s, more often than every 0.25 s")
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
