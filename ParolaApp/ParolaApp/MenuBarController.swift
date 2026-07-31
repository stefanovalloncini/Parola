import AppKit
import ParolaDictation

@MainActor
final class MenuBarController {
    enum Mode: Equatable {
        case hidden
        case full
        case dictationOnly

        init(showExtra: Bool, dictationEnabled: Bool) {
            if showExtra {
                self = .full
            } else if dictationEnabled {
                self = .dictationOnly
            } else {
                self = .hidden
            }
        }
    }

    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private var lastMode: Mode = .hidden
    private var lastSnapshotKey: String = ""
    private var rebuildPending = false

    func bind(_ model: AppModel) {
        self.model = model
        observeAndRefresh()
    }

    private func observeAndRefresh() {
        guard let model else { return }
        withObservationTracking {
            _ = model.showMenuBarExtra
            _ = model.libraryVersion
            _ = model.dictationEnabled
            _ = model.dictationState
            _ = model.libraryEntries
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        refresh()
    }

    private func scheduleRefresh() {
        guard !rebuildPending else { return }
        rebuildPending = true
        Task { @MainActor [weak self] in
            self?.rebuildPending = false
            self?.observeAndRefresh()
        }
    }

    private func refresh() {
        guard let model else { return }
        let mode = Mode(showExtra: model.showMenuBarExtra, dictationEnabled: model.dictationEnabled)
        if mode != lastMode {
            applyVisibility(mode != .hidden)
            lastMode = mode
            lastSnapshotKey = ""
        }
        guard mode != .hidden else { return }
        applyIcon()
        let dictate = Self.dictationMenuItem(for: model.dictationState)
        let key = "\(mode)|\(model.libraryVersion)|\(dictate.stops ? "L" : "-")"
        guard key != lastSnapshotKey else { return }
        lastSnapshotKey = key
        rebuildMenu(mode: mode)
    }

    private func applyVisibility(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                applyIcon()
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
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

    private func applyIcon() {
        guard let model, let button = statusItem?.button else { return }
        let symbol = Self.symbolName(dictationEnabled: model.dictationEnabled, state: model.dictationState)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Parola")
        image?.isTemplate = true
        button.image = image
    }

    private func rebuildMenu(mode: Mode) {
        guard let model, let statusItem else { return }
        let menu = NSMenu()
        let dictateTitle = Self.dictationMenuItem(for: model.dictationState).title

        if mode == .dictationOnly {
            menu.addItem(menuItem(title: dictateTitle, action: #selector(toggleDictation), target: self))
            menu.addItem(.separator())
            menu.addItem(menuItem(title: "Open Parola", action: #selector(openParola), target: self))
            menu.addItem(menuItem(title: "Quit Parola", action: #selector(quitApp), target: self, key: "q"))
            statusItem.menu = menu
            return
        }

        menu.addItem(menuItem(title: "Open Parola", action: #selector(openParola), target: self))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Record from Microphone", action: #selector(recordMic), target: self))
        menu.addItem(menuItem(title: "Open File…", action: #selector(openFile), target: self))
        menu.addItem(menuItem(title: dictateTitle, action: #selector(toggleDictation), target: self))
        menu.addItem(.separator())

        let pinned = model.libraryEntries.filter { $0.pinned }.prefix(5)
        if !pinned.isEmpty {
            let header = NSMenuItem(title: "Pinned", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in pinned {
                let item = NSMenuItem(title: LibraryEntryDisplay.title(for: entry), action: #selector(loadEntryAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let recents = model.libraryEntries
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(8)
        if recents.isEmpty {
            let item = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in recents {
                let item = NSMenuItem(title: LibraryEntryDisplay.title(for: entry), action: #selector(loadEntryAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit Parola", action: #selector(quitApp), target: self, key: "q"))

        statusItem.menu = menu
    }

    private func menuItem(title: String, action: Selector, target: AnyObject, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    @objc private func openParola() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain && !window.title.contains("Mini") {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    @objc private func recordMic() {
        // Bring the main window up so the count-in overlay (and cancel) can be seen.
        openParola()
        model?.startRecording(source: .microphone)
    }

    @objc private func openFile() {
        NSApp.activate(ignoringOtherApps: true)
        model?.presentOpenPanel()
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
