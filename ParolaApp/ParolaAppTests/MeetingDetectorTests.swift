import Foundation
import Testing
@testable import Parola

@Suite("MeetingDetector")
@MainActor
struct MeetingDetectorTests {
    // Both helpers are only touched from the @MainActor test body and the
    // @MainActor closures we hand to MeetingDetector. Single-threaded by isolation.
    final class Clock: @unchecked Sendable {
        var now: Date = Date(timeIntervalSince1970: 1_000_000)
        func advance(by seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    final class Recorder: @unchecked Sendable {
        var calls: [String] = []
    }

    private func make(clock: Clock, recorder: Recorder) -> MeetingDetector {
        let detector = MeetingDetector(
            onDetected: { name in recorder.calls.append(name) },
            clock: { clock.now }
        )
        detector.isEnabled = true
        return detector
    }

    @Test("two fires for the same app within 5s only call the closure once")
    func dedupWindow() {
        let clock = Clock()
        let recorder = Recorder()
        let detector = make(clock: clock, recorder: recorder)

        detector.fire(appName: "Zoom")
        clock.advance(by: 1)
        detector.fire(appName: "Zoom")
        #expect(recorder.calls == ["Zoom"])
    }

    @Test("two fires for the same app 6s apart trigger twice")
    func dedupExpires() {
        let clock = Clock()
        let recorder = Recorder()
        let detector = make(clock: clock, recorder: recorder)

        detector.fire(appName: "Zoom")
        clock.advance(by: 6)
        detector.fire(appName: "Zoom")
        #expect(recorder.calls == ["Zoom", "Zoom"])
    }

    @Test("a different app inside the dedup window still fires")
    func differentAppNotDeduped() {
        let clock = Clock()
        let recorder = Recorder()
        let detector = make(clock: clock, recorder: recorder)

        detector.fire(appName: "Zoom")
        clock.advance(by: 1)
        detector.fire(appName: "Microsoft Teams")
        #expect(recorder.calls == ["Zoom", "Microsoft Teams"])
    }

    @Test("disabled detector ignores fires")
    func disabledDoesNothing() {
        let clock = Clock()
        let recorder = Recorder()
        let detector = make(clock: clock, recorder: recorder)
        detector.isEnabled = false

        detector.fire(appName: "Zoom")
        #expect(recorder.calls.isEmpty)
    }

    final class Running: @unchecked Sendable {
        var apps: Set<String> = []
    }

    private func make(clock: Clock, recorder: Recorder, quits: Recorder, running: Running) -> MeetingDetector {
        let detector = MeetingDetector(
            onDetected: { name in recorder.calls.append(name) },
            onQuit: { name in quits.calls.append(name) },
            clock: { clock.now },
            runningApps: { running.apps }
        )
        detector.isEnabled = true
        return detector
    }

    @Test("a meeting app that quits is let go, unless another copy of it still runs")
    func quitLetsTheAppGo() {
        let quits = Recorder()
        let running = Running()
        let detector = make(clock: Clock(), recorder: Recorder(), quits: quits, running: running)
        detector.fire(appName: "Microsoft Teams")

        running.apps = ["Microsoft Teams"]
        detector.quit(appName: "Microsoft Teams")
        #expect(quits.calls.isEmpty, "the new Teams still runs beside the classic one that quit")

        running.apps = []
        detector.quit(appName: "Microsoft Teams")
        #expect(quits.calls == ["Microsoft Teams"])
    }

    @Test("a meeting app that quits and launches again at once is offered again")
    func relaunchAfterQuitFires() {
        let clock = Clock()
        let recorder = Recorder()
        let detector = make(clock: clock, recorder: recorder, quits: Recorder(), running: Running())

        detector.fire(appName: "Zoom")
        detector.quit(appName: "Zoom")
        clock.advance(by: 1)
        detector.fire(appName: "Zoom")

        #expect(recorder.calls == ["Zoom", "Zoom"])
    }

    @Test("knownMeetingApps maps the supported bundle IDs")
    func knownAppsMapping() {
        let known = MeetingDetector.knownMeetingApps
        #expect(known["us.zoom.xos"] == "Zoom")
        #expect(known["com.microsoft.teams2"] == "Microsoft Teams")
        #expect(known["com.microsoft.teams"] == "Microsoft Teams")
        #expect(known["com.google.Meet"] == "Google Meet")
    }
}
