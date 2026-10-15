import Foundation
import os
import Testing
@testable import Parola
import ParolaCore

@Suite("System capture permissions")
@MainActor
struct SystemCapturePermissionsTests {
    private final class Box: Sendable {
        private struct State {
            var screen = false
            var screenRequestResult = false
            var screenRequests = 0
            var audio: SystemAudioRecordingPermission = .undetermined
            var probeRuns = 0
            var openedPanes: [String] = []
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var screen: Bool { get { state.withLock { $0.screen } } set { state.withLock { $0.screen = newValue } } }
        var screenRequestResult: Bool { get { state.withLock { $0.screenRequestResult } } set { state.withLock { $0.screenRequestResult = newValue } } }
        var screenRequests: Int { get { state.withLock { $0.screenRequests } } set { state.withLock { $0.screenRequests = newValue } } }
        var audio: SystemAudioRecordingPermission { get { state.withLock { $0.audio } } set { state.withLock { $0.audio = newValue } } }
        var probeRuns: Int { get { state.withLock { $0.probeRuns } } set { state.withLock { $0.probeRuns = newValue } } }
        var openedPanes: [String] { get { state.withLock { $0.openedPanes } } set { state.withLock { $0.openedPanes = newValue } } }
    }

    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        try await ParolaLog.withSink(sink) { try await body(sink) }
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

    @Test("a test-mode launch never reaches TCC, and a real launch does")
    func launchGate() {
        var reached = false
        let sandbox = SystemCapturePermissions.forLaunch(sideEffects: BootstrapSideEffect.testing) {
            reached = true
            return make(Box())
        }
        #expect(!reached)
        #expect(!sandbox.screenRecordingGranted)
        #expect(sandbox.systemAudioStatus == .undetermined)

        let box = Box()
        box.screen = true
        let real = SystemCapturePermissions.forLaunch(sideEffects: BootstrapSideEffect.all) {
            reached = true
            return make(box)
        }
        #expect(reached)
        #expect(real.screenRecordingGranted)
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

    @Test("a launch that defers its reads starts neutral, then takes the answer from off the main thread")
    func deferredLaunchRead() async {
        let box = Box()
        box.screen = true
        box.audio = .granted
        let permissions = SystemCapturePermissions(
            screenCheck: { box.screen },
            screenRequest: { false },
            audioCheck: { box.audio },
            consentProbe: {},
            openSettingsPane: { _ in },
            readsAtLaunch: false
        )
        #expect(!permissions.screenRecordingGranted)
        await waitUntil { permissions.screenRecordingGranted }
        #expect(permissions.systemAudioGranted)
    }

    @Test("a background answer that a direct refresh overtook is dropped")
    func staleBackgroundAnswerIsDropped() async {
        let gate = DispatchSemaphore(value: 0)
        let permissions = SystemCapturePermissions(
            screenCheck: {
                if Thread.isMainThread { return false }
                gate.wait()
                return true
            },
            screenRequest: { false },
            audioCheck: { .undetermined },
            consentProbe: {},
            openSettingsPane: { _ in }
        )
        permissions.refreshInBackground()
        permissions.refresh()
        gate.signal()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!permissions.screenRecordingGranted)
    }

    @Test("a launch read that finds a grant logs no change")
    func launchReadIsSilent() async {
        await withSink { sink in
            let permissions = SystemCapturePermissions(
                screenCheck: { true }, screenRequest: { false }, audioCheck: { .granted },
                consentProbe: {}, openSettingsPane: { _ in }, readsAtLaunch: false
            )
            await waitUntil { permissions.screenRecordingGranted }
            #expect(permissions.systemAudioGranted)
            let permissionRecords = sink.records.filter { $0.category == .appPermissions }
            #expect(permissionRecords.isEmpty)
        }
    }
}
