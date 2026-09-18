import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation
import AppKit

@MainActor
@Suite("Menu bar dictation item")
struct MenuBarControllerTests {
    @Test("the item stops only a listening session and starts otherwise")
    func dictationMenuItemStates() {
        let listening = MenuBarController.dictationMenuItem(for: .listening)
        #expect(listening.title == "Stop Dictation")
        #expect(listening.stops)

        let idle = MenuBarController.dictationMenuItem(for: .idle)
        #expect(idle.title == "Start Dictation")
        #expect(idle.stops == false)

        let transcribing = MenuBarController.dictationMenuItem(for: .transcribing)
        #expect(transcribing.title == "Start Dictation")
        #expect(transcribing.stops == false)

        let failed = MenuBarController.dictationMenuItem(for: .failed("x"))
        #expect(failed.title == "Start Dictation")
        #expect(failed.stops == false)
    }
}

@MainActor
@Suite("Menu bar mode")
struct MenuBarModeTests {
    @Test("visibility mode follows the extra toggle and dictation enablement", arguments: [
        (false, false, MenuBarController.Mode.hidden),
        (true, false, .full),
        (true, true, .full),
        (false, true, .dictationOnly),
    ] as [(Bool, Bool, MenuBarController.Mode)])
    func modeMatrix(showExtra: Bool, dictationEnabled: Bool, expected: MenuBarController.Mode) {
        #expect(MenuBarController.Mode(showExtra: showExtra, dictationEnabled: dictationEnabled, features: .all) == expected)
    }

    @Test("icon reflects dictation state only while dictation is enabled")
    func iconMapping() {
        #expect(MenuBarController.symbolName(dictationEnabled: false, state: .listening) == "waveform")
        #expect(MenuBarController.symbolName(dictationEnabled: true, state: .idle) == "mic")
        #expect(MenuBarController.symbolName(dictationEnabled: true, state: .listening) == "mic.fill")
        #expect(MenuBarController.symbolName(dictationEnabled: true, state: .transcribing) == "waveform")
        #expect(MenuBarController.symbolName(dictationEnabled: true, state: .failed("boom")) == "mic.slash")
    }
}

@MainActor
@Suite("Menu bar items builder")
struct MenuBarItemsTests {
    private func fullSnapshot(
        dictateTitle: String = "Start Dictation",
        showsDictation: Bool = true,
        showsMicRecording: Bool = true,
        showsSystemAudio: Bool = true,
        detectedMeetingApp: String? = nil,
        captionsShown: Bool = true,
        captionsActive: Bool = false,
        captionsUnavailableReason: String? = nil,
        inputDevices: [AudioInputDevice] = [],
        selectedInputDeviceUID: String = "",
        showsUpdateCheck: Bool = true,
        pinned: [MenuBarController.MenuSnapshot.Item] = [],
        recents: [MenuBarController.MenuSnapshot.Item] = []
    ) -> MenuBarController.MenuSnapshot {
        MenuBarController.MenuSnapshot(
            mode: .full,
            dictateTitle: dictateTitle,
            showsDictation: showsDictation,
            showsMicRecording: showsMicRecording,
            showsSystemAudio: showsSystemAudio,
            detectedMeetingApp: detectedMeetingApp,
            captionsShown: captionsShown,
            captionsActive: captionsActive,
            captionsUnavailableReason: captionsUnavailableReason,
            inputDevices: inputDevices,
            selectedInputDeviceUID: selectedInputDeviceUID,
            showsUpdateCheck: showsUpdateCheck,
            pinned: pinned,
            recents: recents
        )
    }

    private func titles(_ items: [NSMenuItem]) -> [String] {
        items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    @Test("the full-mode menu lists every item top to bottom")
    func fullMenuOrder() {
        let snapshot = fullSnapshot(
            detectedMeetingApp: "Zoom",
            pinned: [.init(id: "p1", title: "Pinned One")],
            recents: [.init(id: "r1", title: "Recent One")]
        )
        let items = MenuBarController.items(for: snapshot, target: nil)

        #expect(titles(items) == [
            "Open Parola", "—",
            "Record Meeting", "Show Live Captions", "Start Dictation", "Open Files…", "—",
            "Microphone", "Settings…", "Check for Updates…", "—",
            "Pinned", "Pinned One", "—",
            "Recent", "Recent One", "—",
            "Quit Parola",
        ])
    }

    @Test("Record Meeting is hidden when neither meetings nor mic recording is enabled")
    func recordMeetingHiddenWhenBothFeaturesOff() {
        let snapshot = fullSnapshot(showsMicRecording: false, showsSystemAudio: false)
        let items = MenuBarController.items(for: snapshot, target: nil)
        #expect(!titles(items).contains("Record Meeting"))
    }

    @Test("Record Meeting gates each entry by its own feature", arguments: [
        (true, false, ["System Audio"]),
        (false, true, ["Microphone"]),
        (true, true, ["System Audio", "Microphone"]),
    ] as [(Bool, Bool, [String])])
    func recordMeetingGatesEachEntry(showsSystemAudio: Bool, showsMicRecording: Bool, expected: [String]) {
        let snapshot = fullSnapshot(showsMicRecording: showsMicRecording, showsSystemAudio: showsSystemAudio)
        let items = MenuBarController.items(for: snapshot, target: nil)
        let recordMeeting = items.first { $0.title == "Record Meeting" }
        #expect(recordMeeting?.submenu?.items.map(\.title) == expected)
    }

    @Test("the detected app leads the Record Meeting submenu")
    func detectedAppEntryFirst() {
        let snapshot = fullSnapshot(detectedMeetingApp: "Zoom")
        let items = MenuBarController.items(for: snapshot, target: nil)
        let recordMeeting = items.first { $0.title == "Record Meeting" }
        #expect(recordMeeting?.submenu?.items.map(\.title) == ["Zoom", "System Audio", "Microphone"])
    }

    @Test("Live Captions is hidden when the feature is off")
    func liveCaptionsHiddenWhenFeatureOff() {
        let snapshot = fullSnapshot(captionsShown: false)
        let items = MenuBarController.items(for: snapshot, target: nil)
        #expect(!titles(items).contains("Show Live Captions"))
        #expect(!titles(items).contains("Hide Live Captions"))
    }

    @Test("Live Captions title follows the active state")
    func captionsTitleByState() {
        let inactive = MenuBarController.items(for: fullSnapshot(captionsActive: false), target: nil)
        #expect(inactive.first { $0.title.contains("Live Captions") }?.title == "Show Live Captions")

        let active = MenuBarController.items(for: fullSnapshot(captionsActive: true), target: nil)
        #expect(active.first { $0.title.contains("Live Captions") }?.title == "Hide Live Captions")
    }

    @Test("Live Captions is disabled with the unavailable reason as its tooltip")
    func captionsDisabledWithReason() {
        let reason = "Parakeet can't stream Live Captions. Pick a Whisper model first."
        let snapshot = fullSnapshot(captionsUnavailableReason: reason)
        let items = MenuBarController.items(for: snapshot, target: nil)
        let captions = items.first { $0.title.contains("Live Captions") }
        #expect(captions?.isEnabled == false)
        #expect(captions?.toolTip == reason)
    }

    @Test("the microphone submenu checks the selected device, System Default first")
    func microphoneCheckMark() {
        let devices = [
            AudioInputDevice(uid: "a", name: "Mic A", isDefault: false),
            AudioInputDevice(uid: "b", name: "Mic B", isDefault: true),
        ]
        let onSystemDefault = MenuBarController.items(for: fullSnapshot(inputDevices: devices, selectedInputDeviceUID: ""), target: nil)
        let micSubmenuDefault = onSystemDefault.first { $0.title == "Microphone" }?.submenu
        #expect(micSubmenuDefault?.items.map(\.title) == ["System Default", "Mic A", "Mic B"])
        #expect(micSubmenuDefault?.items.map(\.state) == [.on, .off, .off])

        let onDeviceB = MenuBarController.items(for: fullSnapshot(inputDevices: devices, selectedInputDeviceUID: "b"), target: nil)
        let micSubmenuB = onDeviceB.first { $0.title == "Microphone" }?.submenu
        #expect(micSubmenuB?.items.map(\.state) == [.off, .off, .on])
    }

    @Test("Check for Updates is hidden when Sparkle isn't configured")
    func checkForUpdatesHiddenWhenNotConfigured() {
        let hidden = MenuBarController.items(for: fullSnapshot(showsUpdateCheck: false), target: nil)
        #expect(!titles(hidden).contains("Check for Updates…"))

        let shown = MenuBarController.items(for: fullSnapshot(showsUpdateCheck: true), target: nil)
        #expect(titles(shown).contains("Check for Updates…"))
    }

    @Test("dictation-only mode is unchanged")
    func dictationOnlyModeUnchanged() {
        let snapshot = MenuBarController.MenuSnapshot(
            mode: .dictationOnly,
            dictateTitle: "Start Dictation",
            showsDictation: true,
            showsMicRecording: false,
            showsSystemAudio: false
        )
        let items = MenuBarController.items(for: snapshot, target: nil)
        #expect(titles(items) == ["Start Dictation", "—", "Open Parola", "Quit Parola"])
    }
}
