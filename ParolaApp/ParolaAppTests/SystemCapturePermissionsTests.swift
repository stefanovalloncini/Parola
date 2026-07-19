import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("System capture permissions")
@MainActor
struct SystemCapturePermissionsTests {
    // @unchecked: only mutated from @MainActor test bodies and the permissions object's MainActor callbacks.
    private final class Box: @unchecked Sendable {
        var screen = false
        var screenRequestResult = false
        var screenRequests = 0
        var audio: SystemAudioRecordingPermission = .undetermined
        var probeRuns = 0
        var openedPanes: [String] = []
    }

    private func make(_ box: Box) -> SystemCapturePermissions {
        SystemCapturePermissions(
            screenCheck: { box.screen },
            screenRequest: { box.screenRequests += 1; return box.screenRequestResult },
            audioCheck: { box.audio },
            consentProbe: { box.probeRuns += 1; box.audio = .granted },
            openSettingsPane: { box.openedPanes.append($0) }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }

    @Test("initial state mirrors the checks")
    func initialState() {
        let box = Box()
        box.screen = true
        box.audio = .granted
        let permissions = make(box)
        #expect(permissions.screenRecordingGranted == true)
        #expect(permissions.systemAudioGranted == true)
    }

    @Test("refresh picks up changed statuses")
    func refresh() {
        let box = Box()
        let permissions = make(box)
        #expect(permissions.screenRecordingGranted == false)
        #expect(permissions.systemAudioGranted == false)
        box.screen = true
        box.audio = .granted
        permissions.refresh()
        #expect(permissions.screenRecordingGranted == true)
        #expect(permissions.systemAudioGranted == true)
    }

    @Test("screen request falls back to System Settings when not granted")
    func screenRequestFallsBack() {
        let box = Box()
        box.screenRequestResult = false
        let permissions = make(box)
        permissions.requestScreenRecording()
        #expect(box.screenRequests == 1)
        #expect(box.openedPanes == ["Privacy_ScreenCapture"])
    }

    @Test("screen request skips System Settings when the prompt grants")
    func screenRequestGranted() {
        let box = Box()
        box.screenRequestResult = true
        let permissions = make(box)
        permissions.requestScreenRecording()
        #expect(box.openedPanes.isEmpty)
    }

    @Test("undetermined system audio runs the consent probe and refreshes")
    func systemAudioProbe() async {
        let box = Box()
        let permissions = make(box)
        permissions.requestSystemAudio()
        await waitUntil { permissions.systemAudioGranted }
        #expect(box.probeRuns == 1)
        #expect(permissions.systemAudioGranted == true)
        #expect(box.openedPanes.isEmpty)
    }

    @Test("denied system audio opens System Settings instead of probing")
    func systemAudioDenied() {
        let box = Box()
        box.audio = .denied
        let permissions = make(box)
        permissions.requestSystemAudio()
        #expect(box.probeRuns == 0)
        #expect(box.openedPanes == ["Privacy_AudioCapture"])
    }

    @Test("a second request while the probe is in flight does not stack")
    func probeDoesNotStack() async {
        let box = Box()
        let gate = AsyncStream<Void>.makeStream()
        let permissions = SystemCapturePermissions(
            screenCheck: { box.screen },
            screenRequest: { box.screenRequestResult },
            audioCheck: { box.audio },
            consentProbe: {
                box.probeRuns += 1
                for await _ in gate.stream { break }
                box.audio = .granted
            },
            openSettingsPane: { box.openedPanes.append($0) }
        )
        permissions.requestSystemAudio()
        permissions.requestSystemAudio()
        gate.continuation.yield()
        gate.continuation.finish()
        await waitUntil { permissions.systemAudioGranted }
        #expect(box.probeRuns == 1)
    }
}
