import AVFoundation
import Foundation
import Testing
@testable import Parola

@Suite("Dictation permissions")
@MainActor
struct DictationPermissionsTests {
    // @unchecked: only mutated from @MainActor test bodies and the permissions object's MainActor callbacks.
    private final class Box: @unchecked Sendable {
        var trusted = false
        var mic: AVAuthorizationStatus = .notDetermined
        var grantedFired = 0
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
}
