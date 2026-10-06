import AppKit
import SwiftUI
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("CoreAudio device lookups stay off the main thread")
struct CoreAudioMainThreadTests {
    private func makeModel(_ label: String) -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL(label), defaultsOverride: temporaryDefaults(),
            sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
        ))
    }

    private func hangingLookup(releaseAfter seconds: Double = 0.2) -> (
        lookup: @Sendable () -> [AudioInputDevice], ranOnMain: OSAllocatedUnfairLock<Bool?>
    ) {
        let ranOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let hanging = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { hanging.signal() }
        let lookup: @Sendable () -> [AudioInputDevice] = {
            hanging.wait()
            ranOnMain.withLock { $0 = Thread.isMainThread }
            return []
        }
        return (lookup, ranOnMain)
    }

    @Test("the menu bar's hung microphone list never runs on the main thread")
    func menuBarDeviceLookupRunsOffMain() async throws {
        let model = makeModel("menubar-hung-devices")
        model.showMenuBarExtra = true
        let controller = MenuBarController()
        controller.bind(model)
        let (lookup, ranOnMain) = hangingLookup()
        model.inputDevicesLookup = lookup

        controller.menuWillOpen(NSMenu())

        let recorded = await waitUntil { ranOnMain.withLock { $0 } != nil }
        #expect(recorded)
        #expect(ranOnMain.withLock { $0 } == false)
    }

    @Test("the microphone pane's hung device list never runs on the main thread")
    func microphonePaneDeviceLookupRunsOffMain() async throws {
        let model = makeModel("mic-pane-hung-devices")
        let (lookup, ranOnMain) = hangingLookup()
        model.inputDevicesLookup = lookup

        let hosted = HostedWindow(MicrophonePane().environment(model), width: 900, height: 900)
        defer { hosted.close() }

        let recorded = await waitUntil { ranOnMain.withLock { $0 } != nil }
        #expect(recorded)
        #expect(ranOnMain.withLock { $0 } == false)
    }
}
