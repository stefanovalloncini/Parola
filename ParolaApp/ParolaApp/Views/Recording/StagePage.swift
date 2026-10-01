import AppKit
import SwiftUI
import ParolaCore

/// The window while a take runs: a recorder built to be filmed.
struct StagePage: View {
    let take: RecordingSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var isOnScreen = true

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: DS.Spacing.small)
            VStack(spacing: DS.Spacing.small) {
                StageClock(take: take, font: DS.Font.takeTimerStage, rolls: true, ticks: isOnScreen)
                    .foregroundStyle(DS.Color.primaryText)
                StageFacts(take: take, isOnScreen: isOnScreen)
            }
            Spacer(minLength: DS.Spacing.large)
                .frame(maxHeight: 44)
            StageBand(take: take, isOnScreen: isOnScreen)
                .frame(height: StageBand.height)
            Spacer(minLength: DS.Spacing.large)
                .frame(maxHeight: 44)
            stageText
                .frame(minHeight: StageLiveText.minHeight, maxHeight: StageLiveText.height)
                // Ahead of the spacers: a short window gives up spacing first, then lines, never the bar's clearance.
                .layoutPriority(1)
            Spacer(minLength: 0)
            Color.clear
                .frame(height: StageControls.reservedHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(entered || reduceMotion ? 1 : 0.97)
        .opacity(entered ? 1 : 0)
        .overlay(alignment: .bottom) {
            StageControls(take: take)
                .padding(.bottom, StageControls.bottomInset)
                .offset(y: entered || reduceMotion ? 0 : 18)
                .opacity(entered ? 1 : 0)
        }
        .background(WindowShownReader { isOnScreen = $0 })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
        .onAppear(perform: enter)
    }

    @ViewBuilder
    private var stageText: some View {
        if take.isStreaming {
            StageLiveText(isOnScreen: isOnScreen)
        } else {
            LiveQuietLine(text: "Transcript appears when you stop")
        }
    }

    private var accessibilityTitle: LocalizedStringKey {
        let from = take.source.label.lowercased()
        return take.isArming ? "Getting ready to record from \(from)" : "Recording from \(from)"
    }

    /// Only a take that just began plays the entrance; coming back from another page mid-take shows the Stage as it is.
    private func enter() {
        guard take.elapsed(at: Date()) < 1.5 else {
            entered = true
            return
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.25) : DS.Motion.takeEntry) {
            entered = true
        }
    }
}

/// The take's time in whole seconds of capture, pauses left out; it stands still while the take pauses or finishes.
struct StageClock: View {
    let take: RecordingSession
    let font: Font
    var rolls = false
    /// Off while the Stage is out of sight, so the clock stops ticking.
    var ticks = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func text(seconds: Int) -> String {
        AppFormat.elapsed(TimeInterval(seconds))
    }

    var body: some View {
        if ticks, take.state == .recording, let origin = take.clockOrigin {
            TimelineView(.periodic(from: origin, by: 1)) { context in
                face(at: context.date)
            }
        } else {
            face(at: Date())
        }
    }

    private func face(at date: Date) -> some View {
        let seconds = Int(take.elapsed(at: date))
        return Text(verbatim: Self.text(seconds: seconds))
            .font(font)
            .contentTransition(rolls && !reduceMotion ? .numericText() : .identity)
            .animation(rolls && !reduceMotion ? .snappy(duration: 0.3) : nil, value: seconds)
            .accessibilityLabel("Recording time")
            .accessibilityValue(AppFormat.duration(seconds: Double(seconds)))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

extension RecordingSession {
    /// When the take's clock read 0:00, counting its pauses as time it never ran; the clock ticks on whole seconds from here.
    var clockOrigin: Date? {
        startedAt?.addingTimeInterval(pausedTotal)
    }
}

/// The recording light: full strength as each second of the take turns over, easing to 35 % halfway through it.
struct RecDot: View {
    var color: Color = DS.Color.recordingFill
    var side: CGFloat = 8
    var pulsesFrom: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || pulsesFrom == nil)) { context in
            Circle()
                .fill(color)
                .frame(width: side, height: side)
                .opacity(pulsesFrom.map { reduceMotion ? 1 : Self.pulse(at: context.date.timeIntervalSince($0)) } ?? 1)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    nonisolated static func pulse(at elapsed: TimeInterval) -> Double {
        let phase = elapsed - elapsed.rounded(.down)
        return 0.35 + 0.65 * (0.5 + 0.5 * cos(2 * .pi * phase))
    }
}

/// "● REC · MacBook Pro Microphone ⌄ · Live transcript", and under it what needs the user's eye.
struct StageFacts: View {
    let take: RecordingSession
    let isOnScreen: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: DS.Spacing.snug) {
            HStack(spacing: DS.Spacing.snug) {
                status
                separator
                StageDeviceMenu(take: take)
                separator
                Text(verbatim: Self.modeLine(isStreaming: take.isStreaming))
            }
            if let warning {
                Label(warning.message, systemImage: warning.symbol)
                    .foregroundStyle(DS.Color.warningText)
                    .fontWeight(.medium)
            }
        }
        .font(DS.Font.secondary)
        .foregroundStyle(DS.Color.secondaryText)
    }

    static func modeLine(isStreaming: Bool, bundle: Bundle = .main) -> String {
        isStreaming
            ? String(localized: "Live transcript", bundle: bundle)
            : String(localized: "Transcript after you stop", bundle: bundle)
    }

    @ViewBuilder
    private var status: some View {
        if take.isArming {
            HStack(spacing: DS.Spacing.snug) {
                RecDot(color: DS.Color.secondaryText)
                armingLabel
            }
        } else {
            HStack(spacing: DS.Spacing.snug) {
                RecDot(pulsesFrom: isOnScreen && take.state == .recording ? take.clockOrigin : nil)
                Text("REC")
                    .fontWeight(.semibold)
                    .tracking(0.6)
                    .foregroundStyle(DS.Color.dangerText)
            }
        }
    }

    @ViewBuilder
    private var armingLabel: some View {
        if case .arming(.preparingModel(let name, let download)) = take.state {
            HStack(spacing: 0) {
                Text("Preparing \(ModelPickerView.shortLabel(for: AppModel.modelLabel(name)))…")
                if let download {
                    Text(verbatim: " · " + AppFormat.percent(download))
                        .monospacedDigit()
                }
            }
        } else {
            Text("Starting…")
        }
    }

    private var separator: some View {
        Text(verbatim: "·")
            .foregroundStyle(DS.Color.secondaryText.opacity(0.7))
    }

    private var warning: (message: LocalizedStringKey, symbol: String)? {
        if model.recordingDiskSpaceLow {
            return ("Low disk space — recording stops automatically below 200 MB.", "internaldrive")
        }
        guard model.recordingIsSilent else { return nil }
        switch take.source {
        case .microphone: return ("No voice detected — check your microphone.", "speaker.slash.fill")
        case .systemAudio: return ("No sound from your Mac — check that audio is playing.", "speaker.slash.fill")
        }
    }
}

/// The input a take listens on. A take keeps its input to the end, so the menu lists the Mac's inputs without switching.
private struct StageDeviceMenu: View {
    let take: RecordingSession
    @Environment(AppModel.self) private var model
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Group {
            if take.source == .microphone {
                Menu {
                    Picker("Input device", selection: .constant(currentUID)) {
                        ForEach(devices) { device in
                            Text(verbatim: device.name).tag(device.uid)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(true)
                } label: {
                    label(name: take.device ?? String(localized: "Microphone"), opensMenu: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Stop the recording to change the microphone")
                .accessibilityLabel("Input device")
                .accessibilityValue(Text(verbatim: take.device ?? String(localized: "Microphone")))
                .axLeaf("Stage.Menu.Device")
                .task {
                    devices = (try? await AppModel.offMainIO { AudioDevices.inputDevices() }) ?? []
                }
            } else {
                label(name: take.source.meterLabel, opensMenu: false)
            }
        }
        .fixedSize()
    }

    private func label(name: String, opensMenu: Bool) -> some View {
        HStack(spacing: DS.Spacing.tight) {
            Text(verbatim: name)
                .lineLimit(1)
            if opensMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private var currentUID: String {
        model.preferredInputDeviceUID ?? devices.first(where: \.isDefault)?.uid ?? ""
    }
}

/// Whether the window this sits in is on screen: false while it is minimized or hidden with the app.
struct WindowShownReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView()
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [any NSObjectProtocol] = []
        private var reported: Bool?

        isolated deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            // A view joins its window inside SwiftUI's update, which must not change the Stage's state.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            let shown = window.isVisible && !window.isMiniaturized
            guard shown != reported else { return }
            reported = shown
            onChange?(shown)
        }
    }
}
