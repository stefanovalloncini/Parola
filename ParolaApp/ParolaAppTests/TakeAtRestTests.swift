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
    @Test("a paused take's Dock badge waits a whole second, for a clock that can't move")
    func pausedBadgeWait() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let paused = take { take, start in
            _ = take.markCapturing(at: start)
            _ = take.pause(at: start.addingTimeInterval(12.96))
        }
        #expect(DockBadge.secondsToNextTick(for: paused, now: start.addingTimeInterval(300)) == 1)
    }

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
