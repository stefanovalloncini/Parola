import AppKit
import ParolaCore
import ParolaDictation

@MainActor
final class MenuBarController {
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
        var pinned: [Item] = []
        var recents: [Item] = []
    }

    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private(set) var lastSnapshot: MenuSnapshot?

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
            // Tracking is one-shot: re-arm before rebuilding so nothing that lands meanwhile is missed.
            Task { @MainActor in self?.observeAndRefresh() }
        }
        refresh()
    }

    static func snapshot(for model: AppModel) -> MenuSnapshot {
        let mode = Mode(showExtra: model.showMenuBarExtra, dictationEnabled: model.dictationEnabled, features: model.features)
        var snapshot = MenuSnapshot(
            mode: mode,
            dictateTitle: dictationMenuItem(for: model.dictationState).title,
            showsDictation: model.features.isEnabled(.dictation),
            showsMicRecording: model.features.isEnabled(.micRecording),
            showsSystemAudio: model.features.isEnabled(.meetings)
        )
        guard mode == .full else { return snapshot }
        let entries = model.libraryEntries
        snapshot.pinned = entries.lazy.filter(\.pinned).prefix(5).map(Self.item)
        snapshot.recents = RecentEntries.most(of: entries, limit: 8).map(Self.item)
        return snapshot
    }

    private static func item(_ entry: LibraryEntry) -> MenuSnapshot.Item {
        MenuSnapshot.Item(id: entry.id, title: LibraryEntryDisplay.title(for: entry))
    }

    private func refresh() {
        guard let model else { return }
        let snapshot = Self.snapshot(for: model)
        defer { lastSnapshot = snapshot }
        if snapshot.mode != lastSnapshot?.mode {
            applyVisibility(snapshot.mode != .hidden)
        }
        guard snapshot.mode != .hidden else { return }
        applyIcon()
        guard snapshot != lastSnapshot else { return }
        rebuildMenu(snapshot)
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
        let symbol = Self.symbolName(
            dictationEnabled: model.dictationEnabled && model.features.isEnabled(.dictation),
            state: model.dictationState
        )
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Parola")
        image?.isTemplate = true
        button.image = image
    }

    private func rebuildMenu(_ snapshot: MenuSnapshot) {
        guard let statusItem else { return }
        let menu = NSMenu()

        if snapshot.mode == .dictationOnly {
            menu.addItem(menuItem(title: snapshot.dictateTitle, action: #selector(toggleDictation), target: self))
            menu.addItem(.separator())
            menu.addItem(menuItem(title: String(localized: "Open Parola"), action: #selector(openParola), target: self))
            menu.addItem(menuItem(title: String(localized: "Quit Parola"), action: #selector(quitApp), target: self, key: "q"))
            statusItem.menu = menu
            return
        }

        menu.addItem(menuItem(title: String(localized: "Open Parola"), action: #selector(openParola), target: self))
        menu.addItem(.separator())
        if snapshot.showsMicRecording {
            menu.addItem(menuItem(title: String(localized: "Record from Microphone"), action: #selector(recordMic), target: self))
        }
        if snapshot.showsSystemAudio {
            menu.addItem(menuItem(title: String(localized: "Record System Audio"), action: #selector(recordSystem), target: self))
        }
        menu.addItem(menuItem(title: String(localized: "Open File…"), action: #selector(openFile), target: self))
        if snapshot.showsDictation {
            menu.addItem(menuItem(title: snapshot.dictateTitle, action: #selector(toggleDictation), target: self))
        }
        menu.addItem(.separator())

        if !snapshot.pinned.isEmpty {
            let header = NSMenuItem(title: String(localized: "Pinned"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in snapshot.pinned {
                menu.addItem(entryItem(entry))
            }
            menu.addItem(.separator())
        }

        if snapshot.recents.isEmpty {
            let item = NSMenuItem(title: String(localized: "No transcripts yet"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: String(localized: "Recent"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in snapshot.recents {
                menu.addItem(entryItem(entry))
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(title: String(localized: "Quit Parola"), action: #selector(quitApp), target: self, key: "q"))

        statusItem.menu = menu
    }

    private func entryItem(_ entry: MenuSnapshot.Item) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(loadEntryAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry.id
        return item
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

    @objc private func recordSystem() {
        openParola()
        model?.startRecording(source: .systemAudio)
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
