import Foundation
import ParolaCore
import Testing
@testable import Parola

@MainActor
@Suite("Read Aloud activity")
struct ReadAloudActivityTests {
    @Test("an activity is held once while a reading prepares and plays, and not before")
    func heldWhilePlaying() async {
        let rig = ReadAloudRig()
        #expect(rig.activity.held == 0)
        #expect(!rig.controller.activityHeld)

        await rig.start()

        #expect(rig.activity.begun == 1)
        #expect(rig.activity.held == 1)
        #expect(rig.controller.activityHeld)
        await rig.finishUnit()
        await waitUntil { rig.controller.item?.unitIndex == 1 }
        #expect(rig.activity.begun == 1)
    }

    @Test("every state decides whether an activity is held: preparing, reading and waiting hold it, nothing else does", arguments: [
        (ReadAloudController.State.idle, false),
        (.preparing, true),
        (.reading, true),
        (.waiting(.slow), true),
        (.paused(.user), false),
        (.paused(.media), false),
        (.failed("x"), false),
        (.noVoice("fa"), false),
    ] as [(ReadAloudController.State, Bool)])
    func holdsByState(state: ReadAloudController.State, held: Bool) {
        #expect(state.holdsActivity == held)
    }

    @Test("a pause releases it and a resume holds it again")
    func pauseReleases() async {
        let rig = ReadAloudRig()
        await rig.start()

        await rig.controller.pause()
        #expect(rig.activity.held == 0)
        #expect(!rig.controller.activityHeld)

        await rig.controller.resume()
        #expect(rig.activity.held == 1)
        #expect(rig.activity.begun == 2)
    }

    @Test("stop, a finished reading, a failure and quitting each release it")
    func endsRelease() async {
        let stopped = ReadAloudRig()
        await stopped.start()
        await stopped.controller.stop()
        #expect(stopped.activity.held == 0)

        let finished = ReadAloudRig()
        await finished.start(ReadAloudRig.plan(units: 1))
        await finished.finishUnit()
        await waitUntil { finished.controller.state == .idle }
        #expect(finished.activity.held == 0)
        #expect(finished.activity.ended == 1)

        let failing = ReadAloudRig(failAtUnit: 1)
        await failing.start()
        await failing.finishUnit()
        await waitUntil { failing.controller.state.name == "failed" }
        #expect(failing.activity.held == 0)

        let quitting = ReadAloudRig()
        await quitting.start()
        quitting.controller.terminate()
        #expect(quitting.activity.held == 0)
    }

    @Test("a pause for a take releases it")
    func takePauseReleases() async {
        let rig = ReadAloudRig()
        await rig.start()

        rig.controller.yieldNow(to: .take)
        #expect(rig.activity.held == 0)
    }

    @Test("a refused start never holds one")
    func blockedStartHoldsNothing() async {
        let rig = ReadAloudRig()
        rig.blocked = .take

        await rig.controller.start(ReadAloudRig.plan())

        #expect(rig.activity.begun == 0)
    }
}
