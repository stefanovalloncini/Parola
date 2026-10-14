import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation
import ParolaTestSupport
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
        pendingMeetingApp: String? = nil,
        captionsShown: Bool = true,
        captionsActive: Bool = false,
        captionsUnavailableReason: String? = nil,
        inputDevices: [AudioInputDevice] = [],
        selectedInputDeviceUID: String = "",
        showsUpdateCheck: Bool = true,
        showsMicrophonePicker: Bool = true,
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
            pendingMeetingApp: pendingMeetingApp,
            captionsShown: captionsShown,
            captionsActive: captionsActive,
            captionsUnavailableReason: captionsUnavailableReason,
            inputDevices: inputDevices,
            selectedInputDeviceUID: selectedInputDeviceUID,
            showsUpdateCheck: showsUpdateCheck,
            showsMicrophonePicker: showsMicrophonePicker,
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
            "New Recording", "New System Audio Recording", "Record Zoom Meeting",
            "Start Live Captions", "Start Dictation", "Open Files…", "—",
            "Microphone", "Settings…", "Check for Updates…", "—",
            "Pinned", "Pinned One", "—",
            "Recent", "Recent One", "—",
            "Quit Parola",
        ])
    }

    private static let recordTitles: Set<String> = ["New Recording", "New System Audio Recording", "Record Zoom Meeting"]

    @Test("the Record items sit at the top level under the File menu's names, each behind its own feature", arguments: [
        (false, false, []),
        (true, false, ["New System Audio Recording", "Record Zoom Meeting"]),
        (false, true, ["New Recording"]),
        (true, true, ["New Recording", "New System Audio Recording", "Record Zoom Meeting"]),
    ] as [(Bool, Bool, [String])])
    func recordItemsGateByFeature(showsSystemAudio: Bool, showsMicRecording: Bool, expected: [String]) {
        let snapshot = fullSnapshot(
            showsMicRecording: showsMicRecording, showsSystemAudio: showsSystemAudio, detectedMeetingApp: "Zoom"
        )
        let items = MenuBarController.items(for: snapshot, target: nil)
        let record = titles(items).filter { Self.recordTitles.contains($0) }
        let submenus = items.filter { $0.submenu != nil }.map(\.title)
        #expect(record == expected)
        #expect(submenus == ["Microphone"])
    }

    @Test("the Dock menu offers the menu bar's Record, Live Captions and Dictation items, and Stop in place of Record during a take")
    func dockItems() {
        let idle = MenuBarController.dockItems(for: fullSnapshot(detectedMeetingApp: "Zoom"), endTitle: nil, target: nil)
        #expect(titles(idle) == [
            "New Recording", "New System Audio Recording", "Record Zoom Meeting", "Start Live Captions", "Start Dictation",
        ])
        let during = MenuBarController.dockItems(for: fullSnapshot(), endTitle: "Stop Recording", target: nil)
        #expect(titles(during) == ["Stop Recording", "Start Live Captions", "Start Dictation"])
        let bare = MenuBarController.dockItems(
            for: fullSnapshot(showsDictation: false, showsMicRecording: false, showsSystemAudio: false, captionsShown: false),
            endTitle: nil, target: nil
        )
        #expect(bare.isEmpty)
    }

    @Test("Live Captions is hidden when the feature is off")
    func liveCaptionsHiddenWhenFeatureOff() {
        let snapshot = fullSnapshot(captionsShown: false)
        let items = MenuBarController.items(for: snapshot, target: nil)
        #expect(!titles(items).contains("Start Live Captions"))
        #expect(!titles(items).contains("Stop Live Captions"))
    }

    @Test("Live Captions title follows the active state")
    func captionsTitleByState() {
        let inactive = MenuBarController.items(for: fullSnapshot(captionsActive: false), target: nil)
        #expect(inactive.first { $0.title.contains("Live Captions") }?.title == "Start Live Captions")

        let active = MenuBarController.items(for: fullSnapshot(captionsActive: true), target: nil)
        #expect(active.first { $0.title.contains("Live Captions") }?.title == "Stop Live Captions")
    }

    @Test("Live Captions is disabled with the unavailable reason as its tooltip")
    func captionsDisabledWithReason() {
        let reason = "Apple Speech can't show Live Captions. Pick a Whisper or Parakeet model."
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

    @Test("a disabled item stays disabled after AppKit revalidates the menu")
    func autoenablingIsOffEverywhere() {
        let reason = "Apple Speech can't show Live Captions. Pick a Whisper or Parakeet model."
        let snapshot = fullSnapshot(detectedMeetingApp: "Zoom", captionsUnavailableReason: reason)
        let menu = MenuBarController.menu(for: snapshot, target: nil)
        #expect(menu.autoenablesItems == false)
        #expect(menu.items.first { $0.title == "Microphone" }?.submenu?.autoenablesItems == false)

        menu.update()

        #expect(menu.items.first { $0.title.contains("Live Captions") }?.isEnabled == false)
    }

    @Test("a hidden snapshot builds no items")
    func hiddenModeReturnsNoItems() {
        let snapshot = MenuBarController.MenuSnapshot(
            mode: .hidden,
            dictateTitle: "Start Dictation",
            showsDictation: true,
            showsMicRecording: true,
            showsSystemAudio: true
        )
        #expect(MenuBarController.items(for: snapshot, target: nil).isEmpty)
    }

    @Test("Start/Stop Dictation is hidden when the dictation feature is off")
    func dictationGating() {
        let items = MenuBarController.items(for: fullSnapshot(showsDictation: false), target: nil)
        #expect(!titles(items).contains("Start Dictation"))
        #expect(!titles(items).contains("Stop Dictation"))
    }

    @Test("the Microphone picker follows showsMicrophonePicker", arguments: [true, false])
    func microphonePickerGating(showsMicrophonePicker: Bool) {
        let items = MenuBarController.items(for: fullSnapshot(showsMicrophonePicker: showsMicrophonePicker), target: nil)
        let topLevelMicrophoneEntries = items.filter { $0.title == "Microphone" }
        #expect(topLevelMicrophoneEntries.isEmpty == !showsMicrophonePicker)
    }

    @Test("a meeting whose prompt waits leads the menu with Record and Not Now, and isn't offered twice")
    func waitingMeetingLeadsTheMenu() {
        let snapshot = fullSnapshot(
            detectedMeetingApp: "Zoom", pendingMeetingApp: "Zoom", recents: [.init(id: "r1", title: "Recent One")]
        )
        let items = MenuBarController.items(for: snapshot, target: nil)

        #expect(titles(items) == [
            "Record Zoom Meeting", "Not Now", "—",
            "Open Parola", "—",
            "New Recording", "New System Audio Recording",
            "Start Live Captions", "Start Dictation", "Open Files…", "—",
            "Microphone", "Settings…", "Check for Updates…", "—",
            "Recent", "Recent One", "—",
            "Quit Parola",
        ])
        let detected = MenuBarController.items(for: fullSnapshot(detectedMeetingApp: "Zoom"), target: nil)
            .first { $0.title == "Record Zoom Meeting" }
        #expect(items.first?.action == detected?.action)
        #expect(items.first?.representedObject as? String == "Zoom")
        let dock = MenuBarController.dockItems(for: snapshot, endTitle: nil, target: nil)
        #expect(titles(dock).contains("Record Zoom Meeting"), "the Dock menu keeps its own Record items")
        #expect(!titles(dock).contains("Not Now"))
    }

    @Test("a second meeting app detected while the first prompt waits stays under the Record items")
    func otherMeetingStaysUnderRecord() {
        let snapshot = fullSnapshot(detectedMeetingApp: "Microsoft Teams", pendingMeetingApp: "Zoom")
        let items = MenuBarController.items(for: snapshot, target: nil)

        #expect(Array(titles(items).prefix(3)) == ["Record Zoom Meeting", "Not Now", "—"])
        #expect(titles(items).filter { $0.hasPrefix("Record ") } == ["Record Zoom Meeting", "Record Microsoft Teams Meeting"])
    }

    @Test("the detected app records as a meeting, not a plain system-audio capture")
    func detectedAppUsesItsOwnAction() {
        let snapshot = fullSnapshot(detectedMeetingApp: "Zoom")
        let items = MenuBarController.items(for: snapshot, target: nil)
        let zoomItem = items.first { $0.title == "Record Zoom Meeting" }
        let systemAudioItem = items.first { $0.title == "New System Audio Recording" }
        #expect(zoomItem?.action != systemAudioItem?.action)
        #expect(zoomItem?.representedObject as? String == "Zoom")
    }
}

@MainActor
@Suite("Menu bar meeting cue")
struct MenuBarMeetingCueTests {
    enum Exit: String, CaseIterable, CustomTestStringConvertible {
        case appQuits, takeStarts, recordInWindow, notNowInWindow, detectionOff
        var testDescription: String { rawValue }
    }

    private func makeModel(_ label: String) -> AppModel {
        let model = makeRecordingModel("menubar-cue-\(label)")
        model.useStreaming = false
        model.meetingRecordsMicrophone = false
        model.takeCaptureOverride = { _ in StubSource(url: URL(fileURLWithPath: "/dev/null")) }
        model.showMenuBarExtra = true
        model.meetingDetector.isEnabled = true
        return model
    }

    private func pending(_ model: AppModel) -> String? {
        MenuBarController.snapshot(for: model).pendingMeetingApp
    }

    @Test("the menu bar holds a meeting's prompt while it waits, and lets go when the prompt goes", arguments: Exit.allCases)
    func cueFollowsThePrompt(_ exit: Exit) async {
        let model = makeModel("exit-\(exit.rawValue)")
        #expect(pending(model) == nil)

        model.meetingDetector.fire(appName: "Acme Conference")
        #expect(pending(model) == "Acme Conference")

        switch exit {
        case .appQuits: model.meetingDetector.quit(appName: "Acme Conference")
        case .takeStarts: model.startRecording(source: .microphone)
        case .recordInWindow: model.startMeetingRecording()
        case .notNowInWindow: model.dismissMeetingPrompt()
        case .detectionOff: model.meetingDetector.isEnabled = false
        }

        #expect(pending(model) == nil)
        if model.recordingActive {
            await model.discardTake()
            await waitUntil { !model.recordingActive }
        }
        model.meetingDetector.isEnabled = true
    }

    @Test("the menu's Record and Not Now answer the prompt as the alert's buttons do")
    func menuAnswersThePrompt() async {
        let model = makeModel("answers")
        model.showMenuBarExtra = false
        let controller = MenuBarController()
        controller.bind(model)
        func firstItems() -> [NSMenuItem] {
            Array(MenuBarController.items(for: MenuBarController.snapshot(for: model, mode: .full), target: controller).prefix(2))
        }

        model.meetingDetector.fire(appName: "Acme Conference")
        let notNow = firstItems()[1]
        _ = controller.perform(notNow.action, with: notNow)
        #expect(model.meetingDetectedApp == nil)
        #expect(model.recording == nil)

        model.meetingDetector.fire(appName: "Other Conference")
        let record = firstItems()[0]
        #expect(record.title == "Record Other Conference Meeting")
        _ = controller.perform(record.action, with: record)
        #expect(model.meetingDetectedApp == nil)
        #expect(model.activeTake?.category == .meeting)
        await model.discardTake()
        await waitUntil { !model.recordingActive }
    }

    @Test("dictation-only mode and a build without meetings show no cue")
    func noCueWithoutTheFullMenu() {
        let dictationOnly = makeModel("dictation-only")
        dictationOnly.meetingDetectedApp = "Zoom"
        #expect(MenuBarController.snapshot(for: dictationOnly, mode: .dictationOnly).pendingMeetingApp == nil)

        let noMeetings = AppModel(
            skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("menubar-cue-no-meetings"),
            features: [.micRecording]
        )
        noMeetings.showMenuBarExtra = true
        noMeetings.meetingDetectedApp = "Zoom"
        #expect(MenuBarController.snapshot(for: noMeetings).pendingMeetingApp == nil)
    }

    @Test("the menu bar icon shows the cue while the prompt waits and drops it once answered")
    func iconFollowsThePrompt() async {
        let model = makeModel("icon")
        let controller = MenuBarController()
        controller.bind(model)

        model.meetingDetector.fire(appName: "Acme Conference")
        let shown = await waitUntil { controller.cuedMeetingApp == "Acme Conference" }
        #expect(controller.statusButtonAccessibilityLabel == "Parola")
        #expect(controller.statusButtonAccessibilityValue == "Acme Conference is running. Record this meeting with Parola?")
        model.dismissMeetingPrompt()
        let cleared = await waitUntil { controller.cuedMeetingApp == nil }

        #expect(shown)
        #expect(cleared)
        #expect(controller.statusButtonAccessibilityValue == nil)
        #expect(controller.statusButtonAccessibilityLabel == "Parola")
        model.showMenuBarExtra = false
        await waitUntil { controller.lastSnapshot?.mode == .hidden }
    }

    @Test("the cue is a dot in the accent, beside an icon that stays a template")
    func cueIsAnAccentDot() throws {
        let cue = MenuBarController.meetingCue()
        let attachment = try #require(cue.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let dot = try #require(attachment.image)
        #expect(!dot.isTemplate, "a template would draw the dot in the menu bar's ink")

        let center = try #require(Self.color(at: NSPoint(x: dot.size.width / 2, y: dot.size.height / 2), of: dot))
        let accentInkInAqua = Self.inAqua { DS.theme.accentInk.nsColor.usingColorSpace(.sRGB) }
        let accentInk = try #require(accentInkInAqua ?? nil)
        #expect(abs(center.redComponent - accentInk.redComponent) < 0.03)
        #expect(abs(center.greenComponent - accentInk.greenComponent) < 0.03)
        #expect(abs(center.blueComponent - accentInk.blueComponent) < 0.03)
        #expect(cue.string == "\u{FFFC}", "nothing but the dot reaches the title")
    }

    private static func inAqua<T>(_ body: () -> T) -> T? {
        guard let aqua = NSAppearance(named: .aqua) else { return nil }
        var result: T?
        aqua.performAsCurrentDrawingAppearance { result = body() }
        return result
    }

    private static func color(at point: NSPoint, of image: NSImage) -> NSColor? {
        let width = Int(image.size.width.rounded(.up)), height = Int(image.size.height.rounded(.up))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        _ = inAqua { image.draw(in: NSRect(origin: .zero, size: image.size)) }
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: Int(point.x), y: height - 1 - Int(point.y))?.usingColorSpace(.sRGB)
    }
}
