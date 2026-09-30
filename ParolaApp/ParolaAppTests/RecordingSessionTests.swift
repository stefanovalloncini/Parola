import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Recording session")
struct RecordingSessionTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func session(streaming: Bool = false) -> RecordingSession {
        RecordingSession(takeID: 1, source: .microphone, category: .transcription, title: "Recording 30 Sep",
                         isStreaming: streaming, arming: .startingCapture)
    }

    @Test("the clock starts at the first captured buffer, not at the request")
    func clockStartsAtCapture() {
        var take = session()
        #expect(take.elapsed(at: t0.addingTimeInterval(5)) == 0)
        let started = take.markCapturing(at: t0.addingTimeInterval(2))
        #expect(started)
        #expect(take.elapsed(at: t0.addingTimeInterval(5)) == 3)
        let startedAgain = take.markCapturing(at: t0.addingTimeInterval(4))
        #expect(!startedAgain)
        #expect(take.elapsed(at: t0.addingTimeInterval(5)) == 3)
    }

    @Test("paused time never counts, however many pauses")
    func pausesAddUp() {
        var take = session()
        _ = take.markCapturing(at: t0)
        let paused1 = take.pause(at: t0.addingTimeInterval(10))
        #expect(paused1)
        #expect(take.elapsed(at: t0.addingTimeInterval(25)) == 10)
        let resumed1 = take.resume(at: t0.addingTimeInterval(30))
        #expect(resumed1)
        let paused2 = take.pause(at: t0.addingTimeInterval(40))
        #expect(paused2)
        let resumed2 = take.resume(at: t0.addingTimeInterval(100))
        #expect(resumed2)
        #expect(take.elapsed(at: t0.addingTimeInterval(110)) == 30)
        #expect(take.pauses == [10, 20])
    }

    @Test("pause, resume and stop only apply where they make sense")
    func invalidTransitions() {
        var take = session()
        let pausedWhileArming = take.pause(at: t0)
        #expect(!pausedWhileArming)
        _ = take.markCapturing(at: t0)
        let resumedWhileRecording = take.resume(at: t0.addingTimeInterval(1))
        #expect(!resumedWhileRecording)
        let finished = take.finish(at: t0.addingTimeInterval(5))
        #expect(finished)
        let pausedAfterFinish = take.pause(at: t0.addingTimeInterval(6))
        #expect(!pausedAfterFinish)
        let finishedAgain = take.finish(at: t0.addingTimeInterval(7))
        #expect(!finishedAgain)
    }

    @Test("stopping while paused freezes the clock at the pause")
    func stopWhilePaused() {
        var take = session()
        _ = take.markCapturing(at: t0)
        _ = take.pause(at: t0.addingTimeInterval(12))
        let finished = take.finish(at: t0.addingTimeInterval(60))
        #expect(finished)
        #expect(take.elapsed(at: t0.addingTimeInterval(600)) == 12)
        #expect(take.state == .finishing)
    }

    @Test("markers land on the take's own timeline and a double press is one marker")
    func markers() {
        var take = session()
        _ = take.markCapturing(at: t0)
        #expect(take.addMarker(at: t0.addingTimeInterval(5)) == 5)
        _ = take.pause(at: t0.addingTimeInterval(8))
        _ = take.resume(at: t0.addingTimeInterval(20))
        #expect(take.addMarker(at: t0.addingTimeInterval(22)) == 10)
        #expect(take.addMarker(at: t0.addingTimeInterval(22.4)) == nil)
        #expect(take.markers == [5, 10])
    }

    @Test("an arming take can't be marked, and its count-in can advance")
    func arming() {
        var take = RecordingSession(takeID: 2, source: .systemAudio, category: .meeting, title: "Meeting",
                                    isStreaming: false, arming: .countIn(remaining: 3))
        #expect(take.isArming)
        let armed = take.arm(.countIn(remaining: 2))
        #expect(armed)
        #expect(take.addMarker(at: t0) == nil)
        let started = take.markCapturing(at: t0)
        #expect(started)
        let armedAfterCapture = take.arm(.startingCapture)
        #expect(!armedAfterCapture)
    }

    @Test("done and failed are final")
    func endStates() {
        var take = session()
        _ = take.markCapturing(at: t0)
        _ = take.finish(at: t0.addingTimeInterval(3))
        let transcribing1 = take.transcribing(progress: 0.4)
        #expect(transcribing1)
        take.land(entryID: "E1")
        #expect(take.state == .done(entryID: "E1"))
        let transcribing2 = take.transcribing(progress: 0.9)
        #expect(!transcribing2)
        take.fail("late")
        #expect(take.state == .done(entryID: "E1"))
    }

    @Test("a failure during capture keeps the length recorded so far")
    func failureKeepsLength() {
        var take = session()
        _ = take.markCapturing(at: t0)
        take.fail("The microphone stopped.")
        #expect(take.isOver)
        #expect(take.elapsed(at: t0.addingTimeInterval(1)) >= 0)
    }
}
