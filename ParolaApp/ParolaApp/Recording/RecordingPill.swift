import AppKit
import SwiftUI

/// The take while Parola is in the background: "● 12:34 ▂▅▇ ■" floating over other apps, dragged wherever the user likes.
@MainActor
final class RecordingPill {
    nonisolated static let originKey = "recordingPillOrigin"

    private weak var model: AppModel?
    private let makesPanel: Bool
    private let appIsActive: @MainActor () -> Bool
    private var panel: NSPanel?
    private var moveObserver: (any NSObjectProtocol)?
    private var placing = false
    private var failure = OutOfSightFailure()
    private(set) var appActive = true
    private(set) var isShown = false

    /// Without a panel the decision is kept and nothing reaches the screen, as a test wants it. A failure is weighed by `appIsActive`, as the menu bar item and the Dock weigh it, so the three agree.
    init(makesPanel: Bool = true, appIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive }) {
        self.makesPanel = makesPanel
        self.appIsActive = appIsActive
    }

    /// A take that failed, or stopped on its own, while the pill showed it stays, as stopped, until Parola comes to the front.
    nonisolated static func shouldShow(appActive: Bool, takeRunning: Bool, enabled: Bool, failureHeld: Bool = false) -> Bool {
        !appActive && (takeRunning || failureHeld) && enabled
    }

    /// Where the user left it while that spot is still on a screen; else bottom centre of the main screen, above where the dictation overlay sits.
    nonisolated static func frame(size: NSSize, remembered: NSPoint?, screens: [NSRect], fallback: NSRect) -> NSRect {
        if let remembered {
            let kept = NSRect(origin: remembered, size: size)
            if screens.contains(where: { $0.contains(kept) }) { return kept }
        }
        return NSRect(origin: DictationHUDPlacement.aboveOverlayOrigin(for: size, in: fallback), size: size)
    }

    func bind(_ model: AppModel, appActive: Bool) {
        self.model = model
        self.appActive = appActive
        observe()
    }

    func appActiveChanged(_ active: Bool) {
        appActive = active
        if active { failure.release() }
        update()
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    /// All read before the rule combines them, so each stays tracked whichever one decides.
    private func update() {
        guard let model else { return }
        let running = model.takeIsRunning
        let enabled = model.showRecordingPill
        let held = failure.holds(model.recording, stoppedOnItsOwn: model.takeStoppedOnItsOwn, appActive: appIsActive())
        if Self.shouldShow(appActive: appActive, takeRunning: running, enabled: enabled, failureHeld: held) {
            show(model)
        } else {
            hide()
        }
    }

    private func show(_ model: AppModel) {
        guard !isShown else { return }
        isShown = true
        guard makesPanel else { return }
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
    }

    private func hide() {
        guard isShown else { return }
        isShown = false
        panel?.orderOut(nil)
    }

    private func makePanel(_ model: AppModel) -> NSPanel {
        let panel = DictationHUD.make { [weak self] in
            RecordingPillView(
                model: model,
                onShowParola: { self?.showParola() },
                onStop: { TakeRemote.stopOrCancel(model, cancels: $0) },
                onSize: { self?.fit($0) }
            )
        }
        if let size = panel.contentView?.intrinsicContentSize, size.width > 0, size.height > 0 {
            panel.setContentSize(size)
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.remember() }
        }
        return panel
    }

    private func place(_ panel: NSPanel) {
        let frame = Self.frame(
            size: panel.frame.size,
            remembered: rememberedOrigin,
            screens: NSScreen.screens.map(\.visibleFrame),
            fallback: NSScreen.main?.visibleFrame ?? .zero
        )
        placing = true
        panel.setFrame(frame, display: true)
        placing = false
    }

    private func fit(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0, panel.frame.size != size else { return }
        placing = true
        panel.setContentSize(size)
        placing = false
    }

    private var rememberedOrigin: NSPoint? {
        guard let pair = model?.defaults.array(forKey: Self.originKey) as? [Double], pair.count == 2 else { return nil }
        return NSPoint(x: pair[0], y: pair[1])
    }

    private func remember() {
        guard !placing, let panel, let model else { return }
        model.defaults.set([panel.frame.origin.x, panel.frame.origin.y], forKey: Self.originKey)
    }

    private func showParola() {
        guard let model else { return }
        TakeRemote.showParola(model) { model.bringMainWindowForward() }
    }
}

/// The pill as its panel shows it; the face rests while the panel is hidden, as it is while Parola is in front.
struct RecordingPillView: View {
    let model: AppModel
    let onShowParola: () -> Void
    let onStop: (_ cancels: Bool) -> Void
    let onSize: (CGSize) -> Void
    @State private var isOnScreen = true

    var body: some View {
        RecordingPillFace(model: model, isOnScreen: isOnScreen, onShowParola: onShowParola, onStop: onStop, onSize: onSize)
            .background(WindowShownReader { isOnScreen = $0 })
    }
}

/// The pill's face: the take's light and clock, which a click answers with Parola, three bars of level, and a solid red Stop.
struct RecordingPillFace: View {
    let model: AppModel
    /// Off while the panel is hidden, so the clock, the light and the meter stop drawing.
    let isOnScreen: Bool
    let onShowParola: () -> Void
    /// Told whether the button read Cancel when it was clicked.
    let onStop: (_ cancels: Bool) -> Void
    let onSize: (CGSize) -> Void

    nonisolated static let stopSide: CGFloat = 26

    var body: some View {
        if let take = model.recording {
            let warning = TakeRemote.warning(for: take, in: model)
            if let ending = TakeRemote.ending(of: take, stopReason: model.takeStopReason) {
                chrome(stoppedFace(ending), warned: false)
            } else if isOnScreen, take.state == .recording, let origin = take.clockOrigin {
                TimelineView(.periodic(from: origin, by: 1)) { context in
                    chrome(face(take, warning: warning, at: context.date), warned: warning != nil)
                }
            } else {
                chrome(face(take, warning: warning, at: Date()), warned: warning != nil)
            }
        }
    }

    /// A take that failed, or stopped on its own, while Parola was in the background: what happened, and the way back to it.
    private func stoppedFace(_ ending: TakeRemote.Ending) -> some View {
        HStack(spacing: DS.Spacing.regular) {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Color.warningText)
                Text(verbatim: TakeRemote.stoppedTitle())
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.primaryText)
            }
            .help(ending.reason)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: ending.spoken))
            .axLeaf("Label.Stopped")
            Button("Show Recording", action: onShowParola)
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("Button.ShowParola")
        }
    }

    /// A warning rings the pill in amber, so it reads from across the screen.
    private func chrome(_ content: some View, warned: Bool) -> some View {
        content
            .padding(.leading, DS.Spacing.medium)
            .padding(.trailing, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.small)
            .glassEffect(.regular, in: Capsule())
            .overlay {
                if warned {
                    Capsule().strokeBorder(DS.Color.warningText, lineWidth: 1.5)
                }
            }
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .axBranch("RecordingPill")
    }

    /// A warning the Stage would show sits after the clock in amber, and is what the pointer and VoiceOver hear about.
    private func face(_ take: RecordingSession, warning: TakeRemote.Warning?, at now: Date) -> some View {
        HStack(spacing: DS.Spacing.regular) {
            Button(action: onShowParola) {
                HStack(spacing: DS.Spacing.small) {
                    TakeLight(take: take, pulsesFrom: isOnScreen && take.state == .recording ? take.clockOrigin : nil)
                    Text(verbatim: TakeRemote.clock(for: take, now: now))
                        .font(DS.Font.takeTimerCompact)
                        .foregroundStyle(DS.Color.primaryText)
                    if let warning {
                        Image(systemName: warning.symbol)
                            .foregroundStyle(DS.Color.warningText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(warning.map { Text(verbatim: $0.message) } ?? Text("Show Recording"))
            .accessibilityLabel(Text(verbatim: TakeRemote.spokenStatus(for: take, at: now)))
            .accessibilityValue(Text(verbatim: warning?.message ?? ""))
            .accessibilityHint("Show Recording")
            .axLeaf("Button.ShowParola")
            PillMeter(model: model, paused: take.isPaused, isOnScreen: isOnScreen)
            let cancels = take.isArming
            Button { onStop(cancels) } label: {
                Image(systemName: cancels ? "xmark" : "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: Self.stopSide, height: Self.stopSide)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Color.recordingFill))
            }
            .buttonStyle(.plain)
            .disabled(take.state == .finishing)
            .opacity(take.state == .finishing ? DS.Opacity.disabled : 1)
            .help(cancels ? "Cancel the recording before it starts." : "Stop recording and transcribe.")
            .accessibilityLabel(Text(verbatim: TakeRemote.endTitle(for: take)))
            .axLeaf("Button.Stop")
        }
    }
}

/// The take's last three levels as bars, newest on the right, drawn as the band draws its own.
private struct PillMeter: View {
    let model: AppModel
    let paused: Bool
    let isOnScreen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let barCount = 3
    nonisolated static let height: CGFloat = 16

    private var follows: Bool { isOnScreen && !paused }

    var body: some View {
        if reduceMotion {
            TimelineView(.animation(minimumInterval: 0.25, paused: !follows)) { _ in bars }
        } else {
            let _ = follows ? model.takeLevelTick : 0
            bars
        }
    }

    private var bars: some View {
        let levels = model.takeLevels?.recent(Self.barCount) ?? Array(repeating: 0, count: Self.barCount)
        let newest = Double(levels.last ?? 0)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(DS.Color.primaryText.opacity(0.55))
                    .frame(width: 3, height: LevelBars.height(for: levels[index], idle: 3, max: Self.height))
            }
        }
        .frame(height: Self.height, alignment: .bottom)
        .accessibilityRepresentation {
            Text(verbatim: AppFormat.percent(newest))
                .accessibilityLabel("Input level")
                .accessibilityValue(paused ? Text("Paused") : Text(verbatim: AppFormat.percent(newest)))
                .accessibilityAddTraits(.updatesFrequently)
                .axLeaf("Meter.Level")
        }
    }
}
