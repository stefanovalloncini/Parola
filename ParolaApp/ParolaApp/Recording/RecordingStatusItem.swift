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
        /// A first line in the menu that only informs, as a failure's reason.
        var notice: String?
    }

    private weak var model: AppModel?
    private let statusBar: NSStatusBar?
    private let appIsActive: @MainActor () -> Bool
    private var item: NSStatusItem?
    private var tick: Task<Void, Never>?
    private var failure = OutOfSightFailure()
    private(set) var face: Face?

    var isTicking: Bool { tick != nil }

    /// Without a status bar the face is kept and nothing reaches the menu bar, as a test wants it.
    init(statusBar: NSStatusBar? = .system, appIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive }) {
        self.statusBar = statusBar
        self.appIsActive = appIsActive
    }

    func bind(_ model: AppModel) {
        self.model = model
        observe()
    }

    /// Parola is in front: a failure held out of sight is on its Stage or in a notice now.
    func appBecameActive() {
        failure.release()
        if let model { update(model) }
    }

    nonisolated static func menuTitles(for take: RecordingSession) -> [String] {
        controls(for: take).map(\.title)
    }

    nonisolated static func clock(for take: RecordingSession, now: Date) -> String {
        StageClock.text(seconds: Int(take.elapsed(at: now)))
    }

    /// Pause, Mark and Discard… need a capture; Stop has nothing left once the take finishes; a failed take only leads back to Parola.
    nonisolated static func controls(for take: RecordingSession, bundle: Bundle = .main) -> [Control] {
        let showParola = Control(title: String(localized: "Show Parola", bundle: bundle), isEnabled: true, action: #selector(showParola))
        if case .failed = take.state { return [showParola] }
        let canEnd = TakeRemote.canEnd(take)
        let pause = take.isPaused ? String(localized: "Resume", bundle: bundle) : String(localized: "Pause", bundle: bundle)
        return [
            Control(title: String(localized: "Stop Recording", bundle: bundle), isEnabled: canEnd, action: #selector(stop)),
            Control(title: pause, isEnabled: take.isCapturing, action: #selector(togglePause)),
            Control(title: String(localized: "Add Marker", bundle: bundle), isEnabled: take.isCapturing, action: #selector(addMarker)),
            Control(title: String(localized: "Discard…", bundle: bundle), isEnabled: TakeRemote.canDiscard(take), action: #selector(discard)),
            showParola,
        ]
    }

    /// The dot in the take's colour, the clock in digits that hold their width as they turn over; a failed take shows a warning sign and the word for it.
    nonisolated static func attributedTitle(clock: String, lamp: TakeRemote.Lamp) -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString(attributedString: glyph(for: lamp, font: font))
        title.append(NSAttributedString(
            string: " " + clock,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)]
        ))
        return title
    }

    /// A shape as well as a colour where the colour alone would carry the state.
    nonisolated static func glyph(for lamp: TakeRemote.Lamp, font: NSFont) -> NSAttributedString {
        let symbol: String
        switch lamp {
        case .recording, .waiting, .paused:
            return NSAttributedString(string: "●", attributes: [.font: font, .foregroundColor: lamp.tint.nsColor])
        case .stopped: symbol = "exclamationmark.triangle.fill"
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.8, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [lamp.tint.nsColor]))
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        return NSAttributedString(attachment: attachment)
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            update(model)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    /// A failure stays up, as stopped, when it came while Parola was in the background.
    private func update(_ model: AppModel) {
        let enabled = model.showRecordingStatusItem
        let take = model.recording
        let held = failure.holds(take, appActive: appIsActive())
        if enabled, let take, take.isRunning || held {
            show(take, now: Date())
            if take.state == .recording { startTick() } else { stopTick() }
        } else {
            hide()
        }
    }

    nonisolated static func face(for take: RecordingSession, now: Date, bundle: Bundle = .main) -> Face {
        if case .failed(let message) = take.state {
            return Face(
                clock: TakeRemote.stoppedTitle(bundle: bundle),
                lamp: .stopped,
                spoken: TakeRemote.stoppedStatus(message, bundle: bundle),
                controls: controls(for: take, bundle: bundle),
                notice: message
            )
        }
        return Face(
            clock: clock(for: take, now: now),
            lamp: TakeRemote.lamp(for: take),
            spoken: TakeRemote.spokenStatus(for: take, at: now, bundle: bundle),
            controls: controls(for: take, bundle: bundle)
        )
    }

    private func show(_ take: RecordingSession, now: Date) {
        if item == nil, let statusBar {
            let made = statusBar.statusItem(withLength: NSStatusItem.variableLength)
            made.button?.setAccessibilityIdentifier("MenuBar.Button.Recording")
            item = made
        }
        let face = Self.face(for: take, now: now)
        guard face != self.face else { return }
        if face.controls != self.face?.controls || face.notice != self.face?.notice {
            item?.menu = Self.menu(face.controls, notice: face.notice, target: self)
        }
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

    /// What the menu has to say first, then the take's controls, then Show Parola on its own.
    static func menu(_ controls: [Control], notice: String? = nil, target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let notice {
            let line = NSMenuItem(title: firstSentence(of: notice), action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.toolTip = notice
            menu.addItem(line)
        }
        for control in controls {
            if control.action == #selector(showParola), !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: control.title, action: control.action, keyEquivalent: "")
            item.target = target
            item.isEnabled = control.isEnabled
            menu.addItem(item)
        }
        return menu
    }

    /// A menu line doesn't wrap, so a long reason shows its first sentence and keeps the rest for the tooltip.
    nonisolated static func firstSentence(of text: String) -> String {
        guard let end = text.range(of: ". ") else { return text }
        return String(text[..<end.lowerBound]) + "."
    }

    /// Reads the take's clock as each of its seconds turns over, as the Dock badge does; a paused clock needs no reading.
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
        guard let take = model?.recording, take.state == .recording else { return 1 }
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
