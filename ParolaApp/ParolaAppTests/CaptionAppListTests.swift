import Foundation
import Observation
import Testing
import os
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Caption app list")
struct CaptionAppListTests {
    private func running(_ pairs: [(String, String)]) -> [CaptionAppList.Running] {
        pairs.map { CaptionAppList.Running(bundleID: $0.0, name: $0.1) }
    }

    @Test("only running apps with an audio process appear, meeting apps first, the rest by name")
    func orderingAndFiltering() {
        let list = CaptionAppList.list(
            running: running([
                ("com.apple.Safari", "Safari"), ("us.zoom.xos", "Zoom"), ("com.apple.Music", "Music"),
                ("com.apple.TextEdit", "TextEdit"), ("com.microsoft.teams2", "Microsoft Teams"),
            ]),
            audioBundleIDs: ["com.apple.Music", "com.apple.Safari", "us.zoom.xos", "com.microsoft.teams2"],
            ownBundleID: "app.parola.ParolaApp"
        )
        #expect(list.map(\.name) == ["Microsoft Teams", "Zoom", "Music", "Safari"])
        #expect(list.map(\.isMeetingApp) == [true, true, false, false])
    }

    @Test("a helper process under the app's bundle ID counts, and this app never appears")
    func helpersCountAndOwnAppIsLeftOut() {
        let list = CaptionAppList.list(
            running: running([("com.google.Chrome", "Google Chrome"), ("app.parola.ParolaApp", "Parola")]),
            audioBundleIDs: ["com.google.Chrome.helper", "app.parola.ParolaApp"],
            ownBundleID: "app.parola.ParolaApp"
        )
        #expect(list.map(\.bundleID) == ["com.google.Chrome"])
    }

    @Test("a sibling bundle that only shares a prefix does not count")
    func prefixNeedsADot() {
        let list = CaptionAppList.list(
            running: running([("com.apple.Music", "Music")]), audioBundleIDs: ["com.apple.MusicBox"], ownBundleID: nil
        )
        #expect(list.isEmpty)
    }

    @Test("a saved app that isn't running keeps a row that says so")
    func savedAppNotRunning() {
        let apps = CaptionAppList(
            observesChanges: false, ownBundleID: nil,
            runningApps: { [.init(bundleID: "com.apple.Music", name: "Music")] },
            audioBundleIDs: { ["com.apple.Music"] }
        )
        let choices = apps.choices(saved: "app:us.zoom.xos")
        #expect(choices.map(\.setting) == ["app:com.apple.Music", "app:us.zoom.xos"])
        #expect(choices.last?.title == "Zoom (not open)")

        let running = apps.choices(saved: "app:com.apple.Music")
        #expect(running.map(\.title) == ["Music"])
        #expect(apps.choices(saved: "systemAudio").map(\.title) == ["Music"])
    }

    @Test("a saved app that is open but has no audio process yet says so")
    func savedAppOpenWithoutAudio() {
        let apps = CaptionAppList(
            observesChanges: false, ownBundleID: nil,
            runningApps: { [.init(bundleID: "us.zoom.xos", name: "zoom.us")] },
            audioBundleIDs: { [] }
        )
        #expect(apps.choices(saved: "app:us.zoom.xos").map(\.title) == ["Zoom (no audio)"])
    }

    @Test("the saved app's label follows the running list even when no audio process changes")
    func labelFollowsLaunchAndQuit() {
        let running = OSAllocatedUnfairLock<[CaptionAppList.Running]>(initialState: [])
        let apps = CaptionAppList(
            observesChanges: false, ownBundleID: nil,
            runningApps: { running.withLock { $0 } }, audioBundleIDs: { [] }
        )
        let changes = OSAllocatedUnfairLock(initialState: 0)
        @MainActor func track() {
            withObservationTracking { _ = apps.choices(saved: "app:us.zoom.xos") } onChange: { changes.withLock { $0 += 1 } }
        }
        track()
        #expect(apps.choices(saved: "app:us.zoom.xos").map(\.title) == ["Zoom (not open)"])

        running.withLock { $0 = [.init(bundleID: "us.zoom.xos", name: "zoom.us")] }
        apps.refresh()

        #expect(changes.withLock { $0 } == 1, "the menu hears about the launch")
        #expect(apps.choices(saved: "app:us.zoom.xos").map(\.title) == ["Zoom (no audio)"])
    }

    @Test("refresh picks up an app that started playing")
    func refreshFollowsTheReaders() {
        let audio = OSAllocatedUnfairLock<[String]>(initialState: [])
        let apps = CaptionAppList(
            observesChanges: false, ownBundleID: nil,
            runningApps: { [.init(bundleID: "com.apple.Music", name: "Music")] },
            audioBundleIDs: { audio.withLock { $0 } }
        )
        #expect(apps.apps.isEmpty)
        audio.withLock { $0 = ["com.apple.Music"] }
        apps.refresh()
        #expect(apps.apps.map(\.name) == ["Music"])
    }
}

@Suite("Caption failure text")
struct CaptionFailureTests {
    @Test("each permission failure names its pane, and nothing else does")
    func permissions() {
        #expect(CaptionFailure.permission(for: FixedFailureText.systemAudioNotAllowed) == .screenRecording)
        #expect(CaptionFailure.permission(for: FixedFailureText.appAudioNotAllowed) == .systemAudioRecording)
        #expect(CaptionFailure.permission(for: FixedFailureText.microphoneNotStarted) == .microphone)
        #expect(CaptionFailure.permission(for: FixedFailureText.appNotPlayingAudio("us.zoom.xos")) == nil)
        #expect(CaptionFailure.permission(for: "engine died") == nil)
    }

    @Test("the not-playing sentence names the app")
    func notPlaying() {
        let text = CaptionFailure.message(
            for: FixedFailureText.appNotPlayingAudio("us.zoom.xos"), appName: { $0 == "us.zoom.xos" ? "Zoom" : $0 }
        )
        #expect(text == "Zoom isn't playing any audio. Try again once it is.")
    }

    @Test("the ended sentences name the source, and a quit app is named by its display name")
    func ended() {
        #expect(CaptionFailure.message(for: FixedFailureText.systemAudioStopped, appName: { $0 }) == "The system audio stopped.")
        let quit = CaptionFailure.message(
            for: FixedFailureText.appQuit("us.zoom.xos"), appName: { $0 == "us.zoom.xos" ? "Zoom" : $0 }
        )
        #expect(quit == "Zoom quit.")
        let stopped = CaptionFailure.message(
            for: FixedFailureText.appStoppedSending("us.zoom.xos"), appName: { $0 == "us.zoom.xos" ? "Zoom" : $0 }
        )
        #expect(stopped == "Zoom stopped sending audio.")
        #expect(CaptionFailure.permission(for: FixedFailureText.systemAudioStopped) == nil)
        #expect(CaptionFailure.permission(for: FixedFailureText.appQuit("us.zoom.xos")) == nil)
    }

    @Test("only a bundle ID in front of the suffix is read as an app, so an engine error ending in quit is left alone")
    func looseSuffix() {
        let text = "the audio engine quit."
        #expect(CaptionFailure.message(for: text, appName: { _ in "Zoom" }) == FailureText.reason(text, bundle: .main))
        #expect(!CaptionFailure.isCaptureEnd(text))
        #expect(CaptionFailure.isCaptureEnd(FixedFailureText.appQuit("us.zoom.xos")))
        #expect(CaptionFailure.isCaptureEnd(FixedFailureText.systemAudioStopped))
        #expect(!CaptionFailure.isCaptureEnd(FixedFailureText.appNotPlayingAudio("us.zoom.xos")))
    }

    @Test("Italian covers the captions failures")
    func italian() throws {
        let it = try #require(Bundle.main.path(forResource: "it", ofType: "lproj").flatMap(Bundle.init(path:)))
        let notPlaying = CaptionFailure.message(for: FixedFailureText.appNotPlayingAudio("x"), appName: { _ in "Zoom" }, bundle: it)
        #expect(notPlaying == "Zoom non sta riproducendo audio. Riprova quando parte.")
        let quit = CaptionFailure.message(for: FixedFailureText.appQuit("x"), appName: { _ in "Zoom" }, bundle: it)
        #expect(quit == "L'app Zoom è stata chiusa.")
        #expect(CaptionFailure.message(for: FixedFailureText.systemAudioStopped, appName: { $0 }, bundle: it) == "L'audio di sistema si è fermato.")
        let stopped = CaptionFailure.message(for: FixedFailureText.appStoppedSending("x"), appName: { _ in "Zoom" }, bundle: it)
        #expect(stopped == "Zoom ha smesso di inviare audio.")
        for fixed in [FixedFailureText.systemAudioNotAllowed, FixedFailureText.appAudioNotAllowed] {
            let text = CaptionFailure.message(for: fixed, appName: { $0 }, bundle: it)
            #expect(text != fixed && text.hasPrefix("Consenti l'accesso a Parola"), "\(text)")
        }
    }
}

@MainActor
@Suite("Live captions source setting")
struct LiveCaptionsSourceSettingTests {
    @Test("a garbage saved value reads as the microphone, in the picker's tag too, after a reload")
    func garbageIsNormalisedOnReload() {
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("captions-source-garbage"))
        for garbage in ["app:", "speakers", "systemaudio"] {
            defaults.set(garbage, forKey: "liveCaptionsSource")
            model.reloadSettings()
            #expect(model.liveCaptionsSourceRaw == "microphone", "\(garbage)")
        }
    }

    @Test("a reload hands the source to the controller, so Retry follows a reset")
    func reloadReachesTheController() async {
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("captions-source-reload"))
        let controller = LiveCaptionsController(showsPanel: false)
        model.liveCaptions = controller
        await controller.setSource(.systemAudio)
        defaults.removeObject(forKey: "liveCaptionsSource")

        model.reloadSettings()

        await waitUntil { controller.source == .microphone(deviceUID: nil) }
    }

    @Test("Screen Recording is requested only while it isn't granted; granted, the pill opens the pane, and the others always do")
    func permissionPill() {
        func run(screenGranted: Bool, _ permission: RecordingSession.Permission) -> (requested: Int, opened: [RecordingSession.Permission]) {
            let requested = OSAllocatedUnfairLock(initialState: 0)
            let permissions = SystemCapturePermissions(
                screenCheck: { screenGranted }, screenRequest: { requested.withLock { $0 += 1 }; return true },
                audioCheck: { .granted }, consentProbe: {}, openSettingsPane: { _ in }, readsAtLaunch: false
            )
            let opened = OSAllocatedUnfairLock<[RecordingSession.Permission]>(initialState: [])
            AppModel.openCaptionPermission(permission, using: permissions) { permission in opened.withLock { $0.append(permission) } }
            return (requested.withLock { $0 }, opened.withLock { $0 })
        }

        let notGranted = run(screenGranted: false, .screenRecording)
        #expect(notGranted.requested == 1 && notGranted.opened.isEmpty)
        let granted = run(screenGranted: true, .screenRecording)
        #expect(granted.requested == 0 && granted.opened == [.screenRecording])
        let audio = run(screenGranted: false, .systemAudioRecording)
        #expect(audio.requested == 0 && audio.opened == [.systemAudioRecording])
        let mic = run(screenGranted: false, .microphone)
        #expect(mic.requested == 0 && mic.opened == [.microphone])
    }

    @Test("the source is saved, read back, resets with the pane and falls back to the microphone")
    func persistence() {
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("captions-source-setting"))
        #expect(model.liveCaptionsSource == .microphone(deviceUID: nil))

        model.liveCaptionsSourceRaw = "systemAudio"
        #expect(defaults.string(forKey: "liveCaptionsSource") == "systemAudio")
        #expect(model.liveCaptionsSource == .systemAudio)

        model.inputDeviceUID = "usb-mic"
        model.liveCaptionsSourceRaw = "nonsense"
        #expect(model.liveCaptionsSource == .microphone(deviceUID: "usb-mic"))

        #expect(SettingsPaneScope.liveCaptions.defaultsKeys.contains("liveCaptionsSource"))
    }
}
