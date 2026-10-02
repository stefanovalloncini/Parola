import AppKit
import SwiftUI
import ParolaCore

/// The one look the Stage wears for each state of a take's session.
enum StageMode: Equatable {
    case countIn(Int)
    case preparing(String, Double?)
    case starting
    case live
    case paused
    case finishing
    case transcribing(Double?)
    case landing
    case failed(String)

    static func `for`(_ state: RecordingSession.State, isStreaming: Bool) -> StageMode {
        switch state {
        case .arming(.countIn(let remaining)): .countIn(remaining)
        case .arming(.preparingModel(let name, let download)): .preparing(name, download)
        case .arming(.startingCapture): .starting
        case .recording: .live
        case .paused: .paused
        case .finishing: .finishing
        case .transcribing(let progress): .transcribing(progress)
        case .done: .landing
        case .failed(let message): .failed(message)
        }
    }
}

extension RecordingSession {
    var mode: StageMode { StageMode.for(state, isStreaming: isStreaming) }
}

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
                StageTimeSlot(take: take, isOnScreen: isOnScreen)
                    .stageLanding(.time, from: take)
                StageFacts(take: take, isOnScreen: isOnScreen)
                    .leavesFirst()
            }
            Spacer(minLength: DS.Spacing.large)
                .frame(maxHeight: 44)
            stageBand
                .frame(height: StageBand.height)
                .stageLanding(.band, from: take)
            Spacer(minLength: DS.Spacing.large)
                .frame(maxHeight: 44)
            stageText
                .frame(minHeight: StageLiveText.minHeight, maxHeight: StageLiveText.height)
                .leavesFirst()
                // Ahead of the spacers: a short window gives up spacing first, then lines, never the bar's clearance.
                .layoutPriority(1)
            Spacer(minLength: 0)
            Color.clear
                .frame(height: StageControls.reservedHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(Self.entranceScale(entered: entered, reduceMotion: reduceMotion))
        .opacity(Self.entranceOpacity(entered: entered))
        .overlay(alignment: .bottom) {
            StageControls(take: take)
                .leavesFirst()
                .padding(.bottom, StageControls.bottomInset)
                .offset(y: Self.controlsLift(entered: entered, reduceMotion: reduceMotion))
                .opacity(Self.entranceOpacity(entered: entered))
        }
        .background(WindowShownReader { isOnScreen = $0 })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Self.accessibilityTitle(for: take.mode, from: take.source.label.lowercased())))
        .modifier(StageSidebarFold())
        .onAppear(perform: enter)
    }

    @ViewBuilder
    private var stageBand: some View {
        switch take.mode {
        case .transcribing(let progress):
            TakeOverview(progress: progress)
                .padding(.horizontal, DS.Spacing.large)
        default:
            StageBand(take: take, isOnScreen: isOnScreen)
        }
    }

    @ViewBuilder
    private var stageText: some View {
        switch take.mode {
        case .transcribing:
            StageTakeText(isOnScreen: isOnScreen)
        case .failed(let message):
            ErrorBanner(message: message, take: take)
                .frame(maxWidth: StageLiveText.width)
                .padding(.horizontal, DS.Spacing.large)
                .frame(maxHeight: .infinity, alignment: .top)
        default:
            if take.isStreaming {
                StageLiveText(isOnScreen: isOnScreen)
            } else {
                LiveQuietLine(text: "Transcript appears when you stop")
            }
        }
    }

    /// What VoiceOver calls the page: what the take is doing now, paused and finishing included.
    nonisolated static func accessibilityTitle(for mode: StageMode, from: String, bundle: Bundle = .main) -> String {
        switch mode {
        case .countIn, .preparing, .starting: String(localized: "Getting ready to record from \(from)", bundle: bundle)
        case .live, .landing: String(localized: "Recording from \(from)", bundle: bundle)
        case .paused: String(localized: "Recording from \(from), paused", bundle: bundle)
        case .finishing: String(localized: "Finishing the recording", bundle: bundle)
        case .transcribing: String(localized: "Transcribing the recording", bundle: bundle)
        case .failed: String(localized: "The recording stopped", bundle: bundle)
        }
    }

    /// The page grows a touch into place as its controls rise; under Reduce Motion both only fade in.
    nonisolated static func entranceScale(entered: Bool, reduceMotion: Bool) -> CGFloat {
        entered || reduceMotion ? 1 : 0.97
    }

    nonisolated static func controlsLift(entered: Bool, reduceMotion: Bool) -> CGFloat {
        entered || reduceMotion ? 0 : 18
    }

    /// Never fully clear: the entrance starts one hop after the page it replaces is gone, and a clear first frame flashes empty.
    nonisolated static func entranceOpacity(entered: Bool) -> Double {
        entered ? 1 : 0.3
    }

    static func entrance(reduceMotion: Bool) -> Animation {
        reduceMotion ? DS.Motion.crossfade : DS.Motion.takeEntry
    }

    /// Only a take that just began plays the entrance; coming back from another page mid-take shows the Stage as it is.
    private func enter() {
        guard take.elapsed(at: Date()) < 1.5 else {
            entered = true
            return
        }
        // The same hop the sidebar fold waits for, so the two start in one frame and read as one motion.
        Task { @MainActor in
            withAnimation(Self.entrance(reduceMotion: reduceMotion)) {
                entered = true
            }
        }
    }
}

/// The Stage's big line: the take's time, the count-in's number, or the model a live take waits on.
struct StageTimeSlot: View {
    let take: RecordingSession
    let isOnScreen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch take.mode {
            case .countIn(let remaining):
                Text(verbatim: String(remaining))
                    .font(DS.Font.takeTimerStage)
                    .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: remaining)
                    .accessibilityLabel("Count-in")
                    .accessibilityValue(Text(verbatim: String(remaining)))
            case .preparing(let name, let download):
                clockSized {
                    Text(verbatim: Self.preparingText(name: name, download: download))
                        .font(DS.Font.takePreparingStage)
                        .lineLimit(1)
                }
            case .paused:
                StageClock(take: take, font: DS.Font.takeTimerStage, rolls: true, ticks: isOnScreen)
                    .modifier(PausedBlink(blinks: isOnScreen && !reduceMotion))
            default:
                StageClock(take: take, font: DS.Font.takeTimerStage, rolls: true, ticks: isOnScreen)
            }
        }
        .foregroundStyle(DS.Color.primaryText)
    }

    /// "Preparing Whisper Turbo · 42%" while the model downloads, "Preparing Whisper Turbo…" while it loads.
    static func preparingText(name: String, download: Double?, bundle: Bundle = .main) -> String {
        let model = ModelPickerView.shortLabel(for: AppModel.modelLabel(name))
        guard let download else { return String(localized: "Preparing \(model)…", bundle: bundle) }
        return String(localized: "Preparing \(model)", bundle: bundle) + " · " + AppFormat.percent(download)
    }

    /// The clock's own height, so a line of words in its place moves nothing under it.
    private func clockSized<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Text(verbatim: StageClock.text(seconds: 0))
            .font(DS.Font.takeTimerStage)
            .hidden()
            .overlay { content().fixedSize() }
    }
}

/// A paused clock dims for a second in every two, the way a recorder's display blinks on pause.
struct PausedBlink: ViewModifier {
    let blinks: Bool
    @State private var epoch = Date()

    nonisolated static let period: TimeInterval = 2
    nonisolated static let dimmed = 0.3

    func body(content: Content) -> some View {
        if blinks {
            TimelineView(.periodic(from: epoch, by: Self.period / 2)) { context in
                content.opacity(Self.opacity(at: context.date.timeIntervalSince(epoch)))
            }
        } else {
            content
        }
    }

    nonisolated static func opacity(at elapsed: TimeInterval) -> Double {
        let phase = elapsed.truncatingRemainder(dividingBy: period)
        return phase < period / 2 ? 1 : dimmed
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
                if take.isRunning {
                    separator
                    StageDeviceMenu(take: take)
                    separator
                    Text(verbatim: Self.modeLine(isStreaming: take.isStreaming))
                }
            }
            if let warning = TakeRemote.warning(for: take, in: model) {
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

    /// "Transcribing… · 42% · 12 min left" as the run reads the take; "Preparing audio…" while the engine has nothing to count yet.
    nonisolated static func transcribingLine(
        stage: TranscribeStage?, progress: Double?, remaining: TimeInterval? = nil, bundle: Bundle = .main
    ) -> String {
        if progress == nil, stage == .preparingAudio { return String(localized: "Preparing audio…", bundle: bundle) }
        var line = String(localized: "Transcribing…", bundle: bundle)
        guard let progress else { return line }
        line += " · " + AppFormat.percent(progress)
        if let words = LibraryRowFormat.duration(remaining, bundle: bundle) {
            line += " · " + String(localized: "\(words) left", bundle: bundle)
        }
        return line
    }

    private var status: some View {
        HStack(spacing: DS.Spacing.snug) {
            switch take.mode {
            case .countIn, .preparing, .starting:
                RecDot(color: DS.Color.secondaryText)
                Text("Starting…")
            case .paused:
                RecDot(color: DS.Palette.warning)
                statusWord("PAUSED", color: DS.Color.warningText)
            case .finishing:
                RecDot(color: DS.Color.secondaryText)
                statusWord("REC", color: DS.Color.secondaryText)
            case .failed where take.failedWhile == .starting:
                // Above "Couldn't start the recording" a take that never ran has nothing to add; the blank keeps the line's height.
                Text(verbatim: " ")
                    .accessibilityHidden(true)
            case .failed:
                RecDot(color: DS.Color.secondaryText)
                statusWord("STOPPED", color: DS.Color.secondaryText)
            case .transcribing(let progress):
                RecDot(color: DS.Color.accent)
                StageTranscribingStatus(progress: progress, ticks: isOnScreen)
            default:
                RecDot(pulsesFrom: isOnScreen && take.state == .recording ? take.clockOrigin : nil)
                statusWord("REC", color: DS.Color.dangerText)
            }
        }
    }

    private func statusWord(_ word: LocalizedStringKey, color: Color) -> some View {
        Text(word)
            .fontWeight(.semibold)
            .tracking(0.6)
            .foregroundStyle(color)
    }

    private var separator: some View {
        Text(verbatim: "·")
            .foregroundStyle(DS.Color.secondaryText.opacity(0.7))
    }

    /// A quiet meeting that records your microphone heard neither side, so it names both.
    nonisolated static func silenceWarning(source: AppModel.RecordSource, micTrack: MicTrackState?, bundle: Bundle = .main) -> String {
        switch source {
        case .microphone:
            String(localized: "No voice detected — check your microphone.", bundle: bundle)
        case .systemAudio where AppModel.silenceCountsMic(micTrack):
            String(localized: "No sound from your Mac or your microphone.", bundle: bundle)
        case .systemAudio:
            String(localized: "No sound from your Mac — check that audio is playing.", bundle: bundle)
        }
    }
}

/// Its own view, so the engine's stage changes and the countdown redraw this line alone.
struct StageTranscribingStatus: View {
    let progress: Double?
    /// Off while the Stage is out of sight, so the countdown stops ticking.
    let ticks: Bool
    @Environment(AppModel.self) private var model
    @State private var eta = ETACalculator()
    @State private var finish: Date?

    var body: some View {
        Group {
            if ticks, let finish {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    line(remaining: finish.timeIntervalSince(context.date))
                }
            } else {
                line(remaining: finish?.timeIntervalSinceNow)
            }
        }
        .onChange(of: progress, initial: true) { _, value in
            guard let value else {
                eta.reset()
                finish = nil
                return
            }
            eta.observe(progress: value)
            finish = eta.projectedFinish()
        }
    }

    private func line(remaining: TimeInterval?) -> some View {
        Text(verbatim: StageFacts.transcribingLine(stage: model.takeTranscribeStage, progress: progress, remaining: remaining))
            .monospacedDigit()
    }
}

/// The input a take listens on. A take keeps its input to the end, so once it is past its count-in the menu lists the Mac's inputs without switching.
struct StageDeviceMenu: View {
    let take: RecordingSession
    @Environment(AppModel.self) private var model
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Group {
            if take.source == .microphone {
                Menu {
                    Picker("Input device", selection: Binding(get: { checkedRow }, set: { if let uid = $0 { model.chooseTakeInput(uid) } })) {
                        ForEach(Self.rows(devices)) { row in
                            Text(verbatim: row.name).tag(String?.some(row.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(!take.isCountingIn)
                } label: {
                    label(name: deviceName, opensMenu: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help(Self.help(countingIn: take.isCountingIn))
                .accessibilityLabel("Input device")
                .accessibilityValue(Text(verbatim: deviceName))
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

    /// A row of the menu; System Default's id is the empty saved choice.
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// System Default first, as Settings and the menu bar list it, then the Mac's inputs.
    nonisolated static func rows(_ devices: [AudioInputDevice], bundle: Bundle = .main) -> [Row] {
        [Row(id: "", name: String(localized: "System Default", bundle: bundle))] + devices.map { Row(id: $0.uid, name: $0.name) }
    }

    /// The row the menu checks: during a count-in the saved microphone, System Default when it is that or is gone; after, the input the take listens on.
    nonisolated static func checkedRow(countingIn: Bool, takeDevice: String?, savedUID: String, devices: [AudioInputDevice]) -> String? {
        guard countingIn else {
            return checkedUID(takeDevice: takeDevice, preferredUID: savedUID.isEmpty ? nil : savedUID, devices: devices)
        }
        return devices.contains { $0.uid == savedUID } ? savedUID : ""
    }

    nonisolated static func help(countingIn: Bool, bundle: Bundle = .main) -> String {
        countingIn
            ? String(localized: "Choose the microphone Parola records from", bundle: bundle)
            : String(localized: "Stop the recording to change the microphone", bundle: bundle)
    }

    private var checkedRow: String? {
        Self.checkedRow(countingIn: take.isCountingIn, takeDevice: take.device, savedUID: model.inputDeviceUID, devices: devices)
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

    /// Before the take names its input, the one it will open.
    private var deviceName: String {
        take.device ?? devices.first { $0.uid == checkedUID }?.name ?? String(localized: "Microphone")
    }

    private var checkedUID: String {
        Self.checkedUID(takeDevice: take.device, preferredUID: model.preferredInputDeviceUID, devices: devices) ?? ""
    }

    /// The input the take listens on: picked the way the take picked it, the chosen device or else the default, and held to the name the take recorded.
    nonisolated static func checkedUID(takeDevice: String?, preferredUID: String?, devices: [AudioInputDevice]) -> String? {
        let picked = devices.first { $0.uid == preferredUID } ?? devices.first(where: \.isDefault)
        guard let takeDevice else { return picked?.uid }
        if let picked, picked.name == takeDevice { return picked.uid }
        return devices.first { $0.name == takeDevice }?.uid
    }
}
