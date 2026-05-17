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
        let storage = UserDefaults.standard
        storage.set(true, forKey: "meetingDetectorEnabled")
        return MeetingDetector(
            onDetected: { name in recorder.calls.append(name) },
            clock: { clock.now }
        )
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

    @Test("knownMeetingApps maps the supported bundle IDs")
    func knownAppsMapping() {
        let known = MeetingDetector.knownMeetingApps
        #expect(known["us.zoom.xos"] == "Zoom")
        #expect(known["com.microsoft.teams2"] == "Microsoft Teams")
        #expect(known["com.microsoft.teams"] == "Microsoft Teams")
        #expect(known["com.google.Meet"] == "Google Meet")
    }
}
