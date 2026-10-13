import AVFoundation
import Foundation
import os
import Testing
@testable import Parola

@Suite("Dictation permissions")
@MainActor
struct DictationPermissionsTests {
    private final class Box: Sendable {
        private struct State {
            var trusted = false
            var mic: AVAuthorizationStatus = .notDetermined
            var grantedFired = 0
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var trusted: Bool { get { state.withLock { $0.trusted } } set { state.withLock { $0.trusted = newValue } } }
        var mic: AVAuthorizationStatus { get { state.withLock { $0.mic } } set { state.withLock { $0.mic = newValue } } }
        var grantedFired: Int { get { state.withLock { $0.grantedFired } } set { state.withLock { $0.grantedFired = newValue } } }
    }

    private func make(_ box: Box) -> DictationPermissions {
        let permissions = DictationPermissions(
            trustCheck: { box.trusted },
            microphoneStatus: { box.mic }
        )
        permissions.onAccessibilityGranted = { box.grantedFired += 1 }
        return permissions
    }

    @Test("initial state mirrors the checks")
    func initialState() {
        let box = Box()
        box.trusted = true
        box.mic = .authorized
        let permissions = make(box)
        #expect(permissions.accessibilityGranted == true)
        #expect(permissions.microphoneAuthorized == true)
        #expect(permissions.microphoneUndetermined == false)
    }

    @Test("refresh fires the grant callback only on false to true")
    func grantCallback() {
        let box = Box()
        let permissions = make(box)
        permissions.refresh()
        #expect(box.grantedFired == 0)
        box.trusted = true
        permissions.refresh()
        #expect(box.grantedFired == 1)
        permissions.refresh()
        #expect(box.grantedFired == 1)
        box.trusted = false
        permissions.refresh()
        box.trusted = true
        permissions.refresh()
        #expect(box.grantedFired == 2)
    }

    @Test("undetermined microphone is reported")
    func micUndetermined() {
        let box = Box()
        let permissions = make(box)
        #expect(permissions.microphoneAuthorized == false)
        #expect(permissions.microphoneUndetermined == true)
    }

    @Test("polling notices a grant made while the app stays background")
    func pollingNoticesBackgroundGrant() async {
        let box = Box()
        let permissions = DictationPermissions(
            trustCheck: { box.trusted },
            microphoneStatus: { box.mic },
            grantPollInterval: .milliseconds(10)
        )
        permissions.onAccessibilityGranted = { box.grantedFired += 1 }

        permissions.beginWatchingForGrant()
        box.trusted = true

        var spins = 0
        while box.grantedFired == 0, spins < 500 {
            try? await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
        #expect(box.grantedFired == 1, "the poll must notice the grant without a didBecomeActive")
        #expect(permissions.accessibilityGranted)
    }

    private final class SleepLog: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: [Duration]())
        var all: [Duration] { state.withLock { $0 } }
        func append(_ d: Duration) { state.withLock { $0.append(d) } }
    }

    @Test("the poll asks every 2 s for two minutes, then every 15 s, until granted")
    func pollBacksOff() async {
        let box = Box()
        let sleeps = SleepLog()
        let permissions = DictationPermissions(
            trustCheck: { box.trusted },
            microphoneStatus: { box.mic },
            grantPollSleep: { duration in
                sleeps.append(duration)
                if sleeps.all.count == 63 { box.trusted = true }
                await Task.yield()
            }
        )
        permissions.onAccessibilityGranted = { box.grantedFired += 1 }

        permissions.beginWatchingForGrant()
        var spins = 0
        while box.grantedFired == 0, spins < 2000 {
            try? await Task.sleep(for: .milliseconds(5))
            spins += 1
        }

        let all = sleeps.all
        #expect(box.grantedFired == 1)
        #expect(all.count == 63)
        #expect(all.prefix(60).allSatisfy { $0 == .seconds(2) })
        #expect(all.dropFirst(60).allSatisfy { $0 == .seconds(15) })
    }

    @Test("ending the watch stops the poll")
    func endWatchingStopsPoll() async {
        let box = Box()
        let permissions = DictationPermissions(
            trustCheck: { box.trusted },
            microphoneStatus: { box.mic },
            grantPollInterval: .milliseconds(10)
        )
        permissions.onAccessibilityGranted = { box.grantedFired += 1 }

        permissions.beginWatchingForGrant()
        permissions.endWatchingForGrant()
        box.trusted = true
        try? await Task.sleep(for: .milliseconds(100))
        #expect(box.grantedFired == 0)
    }

    @Test("a launch that defers its reads starts neutral, then takes the answer from off the main thread")
    func deferredLaunchRead() async {
        let box = Box()
        box.trusted = true
        box.mic = .authorized
        let permissions = DictationPermissions(
            trustCheck: { box.trusted },
            microphoneStatus: { box.mic },
            readsAtLaunch: false
        )
        #expect(!permissions.accessibilityGranted)
        for _ in 0..<400 where !permissions.accessibilityGranted {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(permissions.accessibilityGranted)
        #expect(permissions.microphoneAuthorized)
    }

    @Test("a background answer that a direct refresh overtook is dropped")
    func staleBackgroundAnswerIsDropped() async {
        let gate = DispatchSemaphore(value: 0)
        let permissions = DictationPermissions(
            trustCheck: {
                if Thread.isMainThread { return false }
                gate.wait()
                return true
            },
            microphoneStatus: { .authorized }
        )
        permissions.refreshInBackground()
        permissions.refresh()
        gate.signal()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!permissions.accessibilityGranted)
    }

    @Test("a launch read that finds Accessibility granted neither fires the grant callback nor logs")
    func launchReadIsSilent() async {
        let box = Box()
        box.trusted = true
        box.mic = .authorized
        let permissions = DictationPermissions(
            trustCheck: { box.trusted },
            microphoneStatus: { box.mic },
            readsAtLaunch: false
        )
        permissions.onAccessibilityGranted = { box.grantedFired += 1 }
        for _ in 0..<400 where !permissions.accessibilityGranted {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(permissions.accessibilityGranted)
        #expect(box.grantedFired == 0)

        box.trusted = false
        permissions.refresh()
        box.trusted = true
        permissions.refresh()
        #expect(box.grantedFired == 1, "later grants still fire")
    }
}
