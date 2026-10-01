import AppKit
import ParolaCore

/// The take in the menu bar while it runs, "● 12:34" with its controls in a menu; an item of its own, so the app's keeps its place.
@MainActor
final class RecordingStatusItem: NSObject {
    struct Control: Equatable {
        let title: String
        let isEnabled: Bool
        let action: Selector
    }

    /// What the item shows; a test reads it back without a status bar.
    struct Face: Equatable {
        var clock: String
        var lamp: TakeRemote.Lamp
        var spoken: String
        var controls: [Control]

        var menuTitles: [String] { controls.map(\.title) }
    }

    private weak var model: AppModel?
    private let statusBar: NSStatusBar?
    private var item: NSStatusItem?
    private var tick: Task<Void, Never>?
    private(set) var face: Face?

    /// Without a status bar the face is kept and nothing reaches the menu bar, as a test wants it.
    init(statusBar: NSStatusBar? = .system) {
        self.statusBar = statusBar
    }

    func bind(_ model: AppModel) {
        self.model = model
        observe()
    }

    nonisolated static func menuTitles(for take: RecordingSession) -> [String] {
        controls(for: take).map(\.title)
    }

    nonisolated static func clock(for take: RecordingSession, now: Date) -> String {
        StageClock.text(seconds: Int(take.elapsed(at: now)))
    }

    nonisolated static func title(for take: RecordingSession, now: Date) -> String {
        "● " + clock(for: take, now: now)
    }

    /// Pause and Mark need a capture; Stop and Discard… have nothing left once the take finishes.
    nonisolated static func controls(for take: RecordingSession, bundle: Bundle = .main) -> [Control] {
        let canEnd = take.state != .finishing
        let pause = take.isPaused ? String(localized: "Resume", bundle: bundle) : String(localized: "Pause", bundle: bundle)
        return [
            Control(title: String(localized: "Stop Recording", bundle: bundle), isEnabled: canEnd, action: #selector(stop)),
            Control(title: pause, isEnabled: take.isCapturing, action: #selector(togglePause)),
            Control(title: String(localized: "Add Marker", bundle: bundle), isEnabled: take.isCapturing, action: #selector(addMarker)),
            Control(title: String(localized: "Discard…", bundle: bundle), isEnabled: canEnd, action: #selector(discard)),
            Control(title: String(localized: "Show Parola", bundle: bundle), isEnabled: true, action: #selector(showParola)),
        ]
    }

    /// The dot in the take's colour, the clock in digits that hold their width as they turn over.
    nonisolated static func attributedTitle(clock: String, lamp: TakeRemote.Lamp) -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString(string: "●", attributes: [.font: font, .foregroundColor: lamp.tint.nsColor])
        title.append(NSAttributedString(
            string: " " + clock,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)]
        ))
        return title
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            update(model)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func update(_ model: AppModel) {
        let enabled = model.showRecordingStatusItem
        if enabled, let take = model.recording, take.isRunning {
            show(take, now: Date())
            startTick()
        } else {
            hide()
        }
    }

    private func show(_ take: RecordingSession, now: Date) {
        if item == nil, let statusBar {
            let made = statusBar.statusItem(withLength: NSStatusItem.variableLength)
            made.button?.setAccessibilityIdentifier("MenuBar.Button.Recording")
            item = made
        }
        let face = Face(
            clock: Self.clock(for: take, now: now),
            lamp: TakeRemote.lamp(for: take),
            spoken: TakeRemote.spokenStatus(for: take, at: now),
            controls: Self.controls(for: take)
        )
        guard face != self.face else { return }
        if face.controls != self.face?.controls { item?.menu = Self.menu(face.controls, target: self) }
        self.face = face
        guard let button = item?.button else { return }
        button.attributedTitle = Self.attributedTitle(clock: face.clock, lamp: face.lamp)
        button.setAccessibilityLabel(face.spoken)
    }

    private func hide() {
        stopTick()
        face = nil
        guard let item else { return }
        statusBar?.removeStatusItem(item)
        self.item = nil
    }

    private static func menu(_ controls: [Control], target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for control in controls {
            let item = NSMenuItem(title: control.title, action: control.action, keyEquivalent: "")
            item.target = target
            item.isEnabled = control.isEnabled
            menu.addItem(item)
        }
        return menu
    }

    /// Reads the take's clock as each of its seconds turns over, as the Dock badge does.
    private func startTick() {
        guard tick == nil else { return }
        tick = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.refresh() else { return }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func stopTick() {
        tick?.cancel()
        tick = nil
    }

    private func refresh() -> Double {
        guard let take = model?.recording, take.isRunning else { return 1 }
        let now = Date()
        show(take, now: now)
        return DockBadge.secondsToNextTick(for: take, now: now)
    }

    @objc private func stop() {
        guard let model else { return }
        TakeRemote.stop(model)
    }

    @objc private func togglePause() {
        guard let model else { return }
        TakeRemote.togglePause(model)
    }

    @objc private func addMarker() {
        guard let model else { return }
        TakeRemote.addMarker(model)
    }

    @objc private func discard() {
        guard let model else { return }
        Task { await TakeRemote.discard(model, confirm: TakeRemote.askToDiscard) }
    }

    @objc private func showParola() {
        guard let model else { return }
        TakeRemote.showParola(model) { model.bringMainWindowForward() }
    }
}
