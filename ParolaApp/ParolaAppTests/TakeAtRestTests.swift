import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private func take(_ state: (inout RecordingSession, Date) -> Void = { _, _ in }) -> RecordingSession {
    var take = RecordingSession(takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: true, arming: .startingCapture)
    let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    state(&take, start)
    return take
}

@Suite("A take at rest wakes nothing")
struct TakeAtRestTests {
    @Test("the caret blinks only while the take records and its Stage is on screen")
    func caret() {
        let recording = take { take, start in _ = take.markCapturing(at: start) }
        let paused = take { take, start in
            _ = take.markCapturing(at: start)
            _ = take.pause(at: start)
        }
        let finishing = take { take, start in
            _ = take.markCapturing(at: start)
            _ = take.finish(at: start)
        }
        #expect(StageLiveText.caretBlinks(isOnScreen: true, take: recording))
        #expect(!StageLiveText.caretBlinks(isOnScreen: false, take: recording))
        #expect(!StageLiveText.caretBlinks(isOnScreen: true, take: paused))
        #expect(!StageLiveText.caretBlinks(isOnScreen: true, take: finishing))
        #expect(!StageLiveText.caretBlinks(isOnScreen: true, take: take()))
        #expect(!StageLiveText.caretBlinks(isOnScreen: true, take: nil))
    }

    @Test("the sidebar row ticks only for a recording take, in a window on screen, with the sidebar open")
    func sidebarRow() {
        let recording = take { take, start in _ = take.markCapturing(at: start) }
        let paused = take { take, start in
            _ = take.markCapturing(at: start)
            _ = take.pause(at: start)
        }
        #expect(SidebarRecordingRow.ticks(recording, windowShown: true, sidebar: .all))
        #expect(SidebarRecordingRow.ticks(recording, windowShown: true, sidebar: .automatic))
        #expect(!SidebarRecordingRow.ticks(recording, windowShown: true, sidebar: .detailOnly), "folded away by the take")
        #expect(!SidebarRecordingRow.ticks(recording, windowShown: false, sidebar: .all))
        #expect(!SidebarRecordingRow.ticks(paused, windowShown: true, sidebar: .all))
    }
}

@MainActor
@Suite("The Dock badge rests with the take", .serialized)
struct DockBadgeRestTests {
    @Test("the Dock badge ticks while the take records, rests while it pauses, and picks up again on resume")
    func ticksOnlyWhileRecording() async throws {
        let audio = try tempWAV("dock-rest")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("dock-rest")
        let badge = DockBadge(show: { _ in }, appIsActive: { true }, requestAttention: {})
        badge.bind(model)
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio), startedAt: Date(timeIntervalSinceNow: -75))
        let ticking = await waitUntil { badge.isTicking }
        #expect(ticking)

        #expect(model.pauseTake())
        let resting = await waitUntil { !badge.isTicking }
        #expect(resting)

        #expect(model.resumeTake())
        let again = await waitUntil { badge.isTicking }
        #expect(again)
        model.endTestTake()
        let stopped = await waitUntil { !badge.isTicking }
        #expect(stopped)
    }
}

@Suite("One clock for a take")
struct TakeClockTickTests {
    private func wait(at elapsed: Double) -> Double {
        let tick = ContinuousClock.now
        let parts = tick.duration(to: AppModel.nextSampleTick(after: tick, now: tick, clock: elapsed)).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    @Test("while the take records, the sampler lands just past each tenth of its clock, so a tick sees each second turn over")
    func samplerFollowsTheClock() {
        #expect(abs(wait(at: 2.33) - 0.072) < 0.000_1)
        #expect(abs(wait(at: 2.999) - 0.003) < 0.000_1, "the tick that turns 0:03 over")
        #expect(abs(wait(at: 3.0015) - 0.0005) < 0.000_1)
        #expect(abs(wait(at: 3.0025) - 0.0995) < 0.000_1)
    }

    @Test("a take whose clock can't move is sampled ten times a second at its own pace, and a long stall is skipped")
    func samplerKeepsItsOwnPace() {
        let tick = ContinuousClock.now
        #expect(AppModel.nextSampleTick(after: tick, now: tick + .milliseconds(40), clock: nil) == tick + .milliseconds(100))
        #expect(AppModel.nextSampleTick(after: tick, now: tick + .seconds(3), clock: nil) == tick + .seconds(3))
    }
}

/// The Dock's labels, in order.
@MainActor
private final class BadgeLabels {
    var labels: [String?] = []
}

@MainActor
@Suite("The take's surfaces read one clock", .serialized)
struct TakeClockSurfaceTests {
    @Test("the take's seconds turn over on the sampler's tick and hold while it pauses; the Dock, the menu bar item and the pill read them")
    func surfacesReadTheTakeClock() async throws {
        let audio = try tempWAV("take-clock")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("take-clock")
        model.useStreaming = false
        model.selectedModel = "openai_whisper-tiny"
        let capture = DeletingCapture(file: audio)
        model.takeCaptureOverride = { _ in capture }
        let shown = BadgeLabels()
        let badge = DockBadge(show: { shown.labels.append($0) }, appIsActive: { true }, requestAttention: {})
        badge.bind(model)
        let item = RecordingStatusItem(statusBar: nil)
        item.bind(model)
        model.startRecording(source: .microphone)
        let recording = await waitUntil { model.recording?.state == .recording }
        try #require(recording)
        let face = RecordingPillFace(model: model, isOnScreen: true, onShowParola: {}, onStop: { _ in }, onSize: { _ in })
        let hosted = HostedWindow(face.environment(model), width: 400, height: 80)
        defer { hosted.close() }
        @MainActor func pill() -> String? {
            HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix("RecordingPill.Button.ShowParola") == true }?.label
        }
        @MainActor func surfacesShowTheClock() -> Bool {
            let clock = StageClock.text(seconds: model.takeClockSeconds)
            return shown.labels.last == .some(clock) && item.face?.clock == clock
        }

        for _ in 0..<2 {
            let second = model.takeClockSeconds
            let spoken = pill()
            let turned = await waitUntil(timeoutMs: 3_000) { model.takeClockSeconds > second }
            #expect(turned)
            let into = (model.recording?.elapsed(at: Date()) ?? 0) - Double(model.takeClockSeconds)
            #expect(into >= 0 && into < 0.5, "the clock read \(model.takeClockSeconds) s with \(into) s of the next gone")
            let read = await waitUntil { surfacesShowTheClock() }
            #expect(read, "the Dock reads \(String(describing: shown.labels.last)), the menu bar \(item.face?.clock ?? "nothing")")
            let spokenAgain = await waitUntil { pill() != spoken }
            #expect(spokenAgain, "the pill still says \(spoken ?? "nothing")")
        }
        #expect(badge.isTicking)
        #expect(item.isTicking)

        #expect(model.pauseTake())
        let held = model.takeClockSeconds
        let resting = await waitUntil { !badge.isTicking && !item.isTicking }
        #expect(resting)
        await settle(for: .milliseconds(1_300))
        #expect(model.takeClockSeconds == held, "a paused clock doesn't turn over")

        #expect(model.resumeTake())
        let again = await waitUntil(timeoutMs: 3_000) { model.takeClockSeconds > held }
        #expect(again)
        let ticking = await waitUntil { badge.isTicking && item.isTicking }
        #expect(ticking)

        await model.discardTake()
        let ended = await waitUntil { !badge.isTicking && item.face == nil }
        #expect(ended)
    }
}
