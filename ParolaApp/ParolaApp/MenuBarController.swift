import AppKit
import ParolaCore
import ParolaDictation

@MainActor
final class MenuBarController: NSObject {
    enum Mode: Equatable {
        case hidden
        case full
        case dictationOnly

        init(showExtra: Bool, dictationEnabled: Bool, features: FeatureSet) {
            if showExtra {
                self = .full
            } else if dictationEnabled, features.isEnabled(.dictation) {
                self = .dictationOnly
            } else {
                self = .hidden
            }
        }
    }

    struct MenuSnapshot: Equatable {
        struct Item: Equatable {
            let id: LibraryEntry.ID
            let title: String
        }

        var mode: Mode
        var dictateTitle: String
        var showsDictation: Bool
        var showsMicRecording: Bool
        var showsSystemAudio: Bool
        var detectedMeetingApp: String? = nil
        /// The meeting whose prompt waits for an answer: the icon carries a dot and the menu offers it first.
        var pendingMeetingApp: String? = nil
        var captionsShown: Bool = false
        var captionsActive: Bool = false
        var captionsUnavailableReason: String? = nil
        var inputDevices: [AudioInputDevice] = []
        var selectedInputDeviceUID: String = ""
        var showsUpdateCheck: Bool = false
        var showsMicrophonePicker: Bool = false
        var pinned: [Item] = []
        var recents: [Item] = []
        /// Off while a take runs, as File ▸ New Recording is: a second Record would only be refused.
        var canRecordMicrophone: Bool = true
        var canRecordSystemAudio: Bool = true
    }

    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private(set) var lastSnapshot: MenuSnapshot?
    private var lastInputDevices: [AudioInputDevice] = []
    private var takeBlocksRecord: Bool?
    /// The meeting the icon's dot stands for; nil while the icon is plain.
    private(set) var cuedMeetingApp: String?

    /// Testing seam: what VoiceOver would read off the status button.
    var statusButtonAccessibilityLabel: String? { statusItem?.button?.accessibilityLabel() }
    var statusButtonAccessibilityValue: String? { statusItem?.button?.accessibilityValue() as? String }

    func bind(_ model: AppModel) {
        self.model = model
        observeAndRefresh()
        observeTake()
    }

    /// Apart from the rest: a take's session changes with every title keystroke, and only its start and end matter here.
    private func observeTake() {
        guard let model else { return }
        let blocks = withObservationTracking {
            model.recordingActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeTake() }
        }
        guard blocks != takeBlocksRecord else { return }
        takeBlocksRecord = blocks
        refresh()
    }

    private func observeAndRefresh() {
        guard let model else { return }
        withObservationTracking {
            _ = model.showMenuBarExtra
            _ = model.libraryVersion
            _ = model.dictationEnabled
            _ = model.dictationState
            _ = model.libraryEntries
            _ = model.inputDeviceUID
            if model.features.isEnabled(.meetings) {
                _ = model.detectedMeetingAppName
                _ = model.meetingDetectedApp
            }
            if model.features.isEnabled(.liveCaptions) {
                _ = model.selectedModel
                _ = model.liveCaptions?.isActive
            }
        } onChange: { [weak self] in
            // Tracking is one-shot: re-arm before rebuilding so nothing that lands meanwhile is missed.
            Task { @MainActor in self?.observeAndRefresh() }
        }
        refresh()
    }

    static func snapshot(for model: AppModel, mode: Mode? = nil) -> MenuSnapshot {
        let mode = mode ?? Mode(showExtra: model.showMenuBarExtra, dictationEnabled: model.dictationEnabled, features: model.features)
        var snapshot = MenuSnapshot(
            mode: mode,
            dictateTitle: dictationMenuItem(for: model.dictationState).title,
            showsDictation: model.features.isEnabled(.dictation),
            showsMicRecording: model.features.isEnabled(.micRecording),
            showsSystemAudio: model.features.isEnabled(.meetings)
        )
        guard mode == .full else { return snapshot }
        if model.features.isEnabled(.meetings) {
            snapshot.detectedMeetingApp = model.detectedMeetingAppName
            snapshot.pendingMeetingApp = model.meetingDetectedApp
        }
        if model.features.isEnabled(.liveCaptions) {
            snapshot.captionsShown = true
            snapshot.captionsActive = model.liveCaptions?.isActive ?? false
            snapshot.captionsUnavailableReason = model.liveCaptionsUnavailableReason
        }
        snapshot.selectedInputDeviceUID = model.inputDeviceUID
        snapshot.canRecordMicrophone = model.canStartTake(.microphone)
        snapshot.canRecordSystemAudio = model.canStartTake(.systemAudio)
        snapshot.showsUpdateCheck = SparkleUpdater.feedURLConfigured
        snapshot.showsMicrophonePicker = SettingsRoute.microphone.isVisible(features: model.features)
        let entries = model.libraryEntries
        snapshot.pinned = entries.lazy.filter(\.pinned).prefix(5).map { Self.item($0, showsAITitle: model.showAITitles) }
        snapshot.recents = RecentEntries.most(of: entries, limit: 8).map { Self.item($0, showsAITitle: model.showAITitles) }
        return snapshot
    }

    private static func item(_ entry: LibraryEntry, showsAITitle: Bool) -> MenuSnapshot.Item {
        MenuSnapshot.Item(id: entry.id, title: LibraryEntryDisplay.listTitle(for: entry, showsAITitle: showsAITitle))
    }

    private func refresh() {
        guard let model else { return }
        let snapshot = Self.snapshot(for: model)
        defer { lastSnapshot = snapshot }
        if snapshot.mode != lastSnapshot?.mode {
            applyVisibility(snapshot.mode != .hidden)
        }
        guard snapshot.mode != .hidden else { return }
        applyIcon(meetingCue: snapshot.pendingMeetingApp)
        guard snapshot != lastSnapshot else { return }
        rebuildMenu(snapshot)
    }

    private func applyVisibility(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            cuedMeetingApp = nil
        }
    }

    static func symbolName(dictationEnabled: Bool, state: DictationCoordinator.State) -> String {
        guard dictationEnabled else { return "waveform" }
        switch state {
        case .idle: return "mic"
        case .listening: return "mic.fill"
        case .transcribing: return "waveform"
        case .failed: return "mic.slash"
        }
    }

    private func applyIcon(meetingCue app: String?) {
        guard let model, let button = statusItem?.button else { return }
        let symbol = Self.symbolName(
            dictationEnabled: model.dictationEnabled && model.features.isEnabled(.dictation),
            state: model.dictationState
        )
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Parola")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = app == nil ? .imageOnly : .imageLeading
        button.imageHugsTitle = true
        button.attributedTitle = app == nil ? NSAttributedString() : Self.meetingCue()
        button.setAccessibilityLabel(app == nil ? nil : "Parola")
        button.setAccessibilityValue(app.map(Self.meetingCueSpokenValue))
        cuedMeetingApp = app
    }

    /// The alert's own title and body, said together — the dot's attachment carries no title of its own for VoiceOver to read.
    static func meetingCueSpokenValue(for app: String) -> String {
        "\(String(localized: "\(app) is running")). \(String(localized: "Record this meeting with Parola?"))"
    }

    /// A dot in `accentInk` after the icon, raised to its top; the icon stays a template, so it keeps the menu bar's ink.
    /// The raw accent is near-invisible for some presets against the menu bar's chrome; `accentInk` is already tuned for it.
    static func meetingCue(font: NSFont = .menuBarFont(ofSize: 0)) -> NSAttributedString {
        let diameter: CGFloat = 6
        let accentInk = DS.theme.accentInk.nsColor
        let dot = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            accentInk.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = dot
        attachment.bounds = NSRect(x: 0, y: font.capHeight - diameter, width: diameter, height: diameter)
        return NSAttributedString(attachment: attachment)
    }

    private func rebuildMenu(_ snapshot: MenuSnapshot) {
        guard let statusItem else { return }
        let menu = Self.menu(for: snapshot, target: self)
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Menu builder

    private static let microphoneItemIdentifier = NSUserInterfaceItemIdentifier("MenuBar.Microphone")

    /// An autoenabling `NSMenu` would silently re-enable a disabled item (e.g. Live Captions) on display.
    static func menu(for snapshot: MenuSnapshot, target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items(for: snapshot, target: target) {
            menu.addItem(item)
        }
        return menu
    }

    /// A nil target leaves every item unwired.
    static func items(for snapshot: MenuSnapshot, target: AnyObject?) -> [NSMenuItem] {
        switch snapshot.mode {
        case .hidden:
            return []
        case .dictationOnly:
            return [
                menuItem(title: snapshot.dictateTitle, action: #selector(toggleDictation), target: target),
                .separator(),
                menuItem(title: String(localized: "Open Parola"), action: #selector(openParola), target: target),
                menuItem(title: String(localized: "Quit Parola"), action: #selector(quitApp), target: target, key: "q"),
            ]
        case .full:
            break
        }

        var items: [NSMenuItem] = []
        if let app = snapshot.pendingMeetingApp {
            items.append(detectedMeetingItem(app, enabled: snapshot.canRecordSystemAudio, target: target))
            items.append(menuItem(title: String(localized: "Not Now"), action: #selector(dismissMeetingPrompt), target: target))
            items.append(.separator())
        }
        items.append(menuItem(title: String(localized: "Open Parola"), action: #selector(openParola), target: target))
        items.append(.separator())

        items.append(contentsOf: recordItems(for: snapshot, target: target, offeredAbove: snapshot.pendingMeetingApp))
        if snapshot.captionsShown {
            items.append(liveCaptionsItem(for: snapshot, target: target))
        }
        if snapshot.showsDictation {
            items.append(menuItem(title: snapshot.dictateTitle, action: #selector(toggleDictation), target: target))
        }
        items.append(menuItem(title: String(localized: "Open Files…"), action: #selector(openFile), target: target))
        items.append(.separator())

        if snapshot.showsMicrophonePicker {
            items.append(microphoneItem(for: snapshot, target: target))
        }
        items.append(menuItem(title: String(localized: "Settings…"), action: #selector(openSettings), target: target, key: ","))
        if snapshot.showsUpdateCheck {
            items.append(menuItem(title: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), target: target))
        }
        items.append(.separator())

        if !snapshot.pinned.isEmpty {
            let header = NSMenuItem(title: String(localized: "Pinned"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            items.append(header)
            items.append(contentsOf: snapshot.pinned.map { entryItem($0, target: target) })
            items.append(.separator())
        }

        if snapshot.recents.isEmpty {
            let noneItem = NSMenuItem(title: String(localized: "No transcripts yet"), action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            items.append(noneItem)
        } else {
            let header = NSMenuItem(title: String(localized: "Recent"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            items.append(header)
            items.append(contentsOf: snapshot.recents.map { entryItem($0, target: target) })
        }
        items.append(.separator())
        items.append(menuItem(title: String(localized: "Quit Parola"), action: #selector(quitApp), target: target, key: "q"))
        return items
    }

    /// The File menu's names, with the detected meeting after them as in the toolbar's Record menu, unless the menu already offers it above.
    static func recordItems(for snapshot: MenuSnapshot, target: AnyObject?, offeredAbove: String? = nil) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if snapshot.showsMicRecording {
            let mic = menuItem(title: String(localized: "New Recording"), action: #selector(recordMic), target: target)
            mic.isEnabled = snapshot.canRecordMicrophone
            items.append(mic)
        }
        guard snapshot.showsSystemAudio else { return items }
        let system = menuItem(title: String(localized: "New System Audio Recording"), action: #selector(recordSystem), target: target)
        system.isEnabled = snapshot.canRecordSystemAudio
        items.append(system)
        if let app = snapshot.detectedMeetingApp, app != offeredAbove {
            items.append(detectedMeetingItem(app, enabled: snapshot.canRecordSystemAudio, target: target))
        }
        return items
    }

    private static func detectedMeetingItem(_ app: String, enabled: Bool, target: AnyObject?) -> NSMenuItem {
        let item = menuItem(title: String(localized: "Record \(app) Meeting"), action: #selector(recordDetectedMeeting(_:)), target: target)
        item.representedObject = app
        item.isEnabled = enabled
        return item
    }

    /// The Dock icon's menu, whatever the menu bar shows; a nil target leaves every item unwired.
    static func dockItems(for snapshot: MenuSnapshot, endTitle: String?, target: AnyObject?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let endTitle {
            items.append(menuItem(title: endTitle, action: #selector(endTake), target: target))
        } else {
            items.append(contentsOf: recordItems(for: snapshot, target: target))
        }
        if snapshot.captionsShown {
            items.append(liveCaptionsItem(for: snapshot, target: target))
        }
        if snapshot.showsDictation {
            items.append(menuItem(title: snapshot.dictateTitle, action: #selector(toggleDictation), target: target))
        }
        return items
    }

    func dockMenu() -> NSMenu? {
        guard let model else { return nil }
        let take = model.recording
        let endTitle = TakeRemote.canEnd(take) ? TakeRemote.endTitle(for: take) : nil
        let items = Self.dockItems(for: Self.snapshot(for: model, mode: .full), endTitle: endTitle, target: self)
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            menu.addItem(item)
        }
        return menu
    }

    private static func liveCaptionsItem(for snapshot: MenuSnapshot, target: AnyObject?) -> NSMenuItem {
        let title = snapshot.captionsActive
            ? String(localized: "Stop Live Captions")
            : String(localized: "Start Live Captions")
        let item = menuItem(title: title, action: #selector(toggleLiveCaptions), target: target)
        if let reason = snapshot.captionsUnavailableReason {
            item.isEnabled = false
            item.toolTip = reason
        }
        return item
    }

    private static func microphoneItem(for snapshot: MenuSnapshot, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Microphone"), action: nil, keyEquivalent: "")
        item.identifier = microphoneItemIdentifier
        item.submenu = microphoneSubmenu(devices: snapshot.inputDevices, selectedUID: snapshot.selectedInputDeviceUID, target: target)
        return item
    }

    private static func microphoneSubmenu(devices: [AudioInputDevice], selectedUID: String, target: AnyObject?) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let systemDefault = menuItem(title: String(localized: "System Default"), action: #selector(selectInputDevice(_:)), target: target)
        systemDefault.representedObject = ""
        systemDefault.state = selectedUID.isEmpty ? .on : .off
        submenu.addItem(systemDefault)
        for device in devices {
            let deviceItem = menuItem(title: device.name, action: #selector(selectInputDevice(_:)), target: target)
            deviceItem.representedObject = device.uid
            deviceItem.state = device.uid == selectedUID ? .on : .off
            submenu.addItem(deviceItem)
        }
        return submenu
    }

    private static func entryItem(_ entry: MenuSnapshot.Item, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(loadEntryAction(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = entry.id
        return item
    }

    private static func menuItem(title: String, action: Selector, target: AnyObject?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    @objc private func openParola() {
        model?.bringMainWindowForward()
    }

    /// Parola stays where it is: a take started here runs behind the menu bar item and the pill.
    @objc private func recordMic() {
        model?.startRecording(source: .microphone)
    }

    @objc private func recordSystem() {
        model?.startRecording(source: .systemAudio)
    }

    @objc private func endTake() {
        guard let model else { return }
        TakeRemote.stopOrCancel(model, cancels: model.recording?.isArming == true)
    }

    @objc private func recordDetectedMeeting(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        model?.startMeetingRecording(appName: app)
    }

    @objc private func dismissMeetingPrompt() {
        model?.dismissMeetingPrompt()
    }

    @objc private func openFile() {
        NSApp.activate(ignoringOtherApps: true)
        model?.presentOpenPanel()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func checkForUpdates() {
        SparkleUpdater.shared.checkForUpdates()
    }

    @objc private func toggleLiveCaptions() {
        model?.toggleLiveCaptions()
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        model?.inputDeviceUID = uid
    }

    /// Keyed to the session, not the enabled flag: "Stop" on an enabled-but-idle
    /// dictation was a dead item that could never actually stop anything.
    static func dictationMenuItem(for state: DictationCoordinator.State) -> (title: String, stops: Bool) {
        if case .listening = state {
            return (String(localized: "Stop Dictation"), true)
        }
        return (String(localized: "Start Dictation"), false)
    }

    @objc private func toggleDictation() {
        guard let model else { return }
        if Self.dictationMenuItem(for: model.dictationState).stops {
            model.stopDictationFromIntent()
        } else {
            model.startDictationFromIntent()
        }
    }

    @objc private func loadEntryAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        model?.loadEntry(id)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    /// CoreAudio device attach/detach isn't Observation-tracked, so the picker re-scans on open.
    func menuWillOpen(_ menu: NSMenu) {
        guard let model, lastSnapshot?.showsMicrophonePicker == true else { return }
        installMicrophoneSubmenu(devices: lastInputDevices, into: menu, selectedUID: model.inputDeviceUID)
        Task { @MainActor [weak self] in
            guard let self, let model = self.model else { return }
            let lookup = model.inputDevicesLookup
            let devices = await AppModel.askCoreAudio { lookup() }
            guard devices != self.lastInputDevices else { return }
            self.lastInputDevices = devices
            self.installMicrophoneSubmenu(devices: devices, into: menu, selectedUID: model.inputDeviceUID)
        }
    }

    private func installMicrophoneSubmenu(devices: [AudioInputDevice], into menu: NSMenu, selectedUID: String) {
        for item in menu.items where item.identifier == Self.microphoneItemIdentifier {
            item.submenu = Self.microphoneSubmenu(devices: devices, selectedUID: selectedUID, target: self)
        }
    }
}
