import AppKit

@MainActor
final class MenuBarController {
    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private var lastVisibility: Bool = false
    private var lastSnapshotKey: String = ""
    private var rebuildPending = false

    func bind(_ model: AppModel) {
        self.model = model
        applyVisibility(model.showMenuBarExtra)
        observeAndRefresh()
    }

    private func observeAndRefresh() {
        guard let model else { return }
        withObservationTracking {
            _ = model.showMenuBarExtra
            _ = model.libraryVersion
            _ = model.dictationEnabled
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
        if model.showMenuBarExtra != lastVisibility {
            applyVisibility(model.showMenuBarExtra)
            lastVisibility = model.showMenuBarExtra
        }
        guard model.showMenuBarExtra else { return }
        let key = "\(model.libraryVersion)|\(model.dictationEnabled ? "1" : "0")"
        guard key != lastSnapshotKey else { return }
        lastSnapshotKey = key
        rebuildMenu()
    }

    private func applyVisibility(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Parola")
                statusItem = item
                rebuildMenu()
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func rebuildMenu() {
        guard let model, let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(menuItem(title: "Open Parola", action: #selector(openParola), target: self))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Record from Microphone", action: #selector(recordMic), target: self))
        menu.addItem(menuItem(title: "Open File…", action: #selector(openFile), target: self))
        let dictateTitle = model.dictationEnabled ? "Stop Dictation" : "Start Dictation"
        menu.addItem(menuItem(title: dictateTitle, action: #selector(toggleDictation), target: self))
        menu.addItem(.separator())

        let pinned = model.libraryEntries.filter { $0.pinned }.prefix(5)
        if !pinned.isEmpty {
            let header = NSMenuItem(title: "Pinned", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in pinned {
                let item = NSMenuItem(title: entry.title, action: #selector(loadEntryAction(_:)), keyEquivalent: "")
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
                let item = NSMenuItem(title: entry.title, action: #selector(loadEntryAction(_:)), keyEquivalent: "")
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

    @objc private func toggleDictation() {
        guard let model else { return }
        if model.dictationEnabled {
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
