import SwiftUI
import ParolaCore

/// What the Now Reading item shows for a reading's state, whether a take runs, and how wide the window is.
enum NowReadingLayout: Equatable {
    case hidden
    case full
    case compact
    case failed
    case failedCompact

    static let fullWidth: CGFloat = 1000

    static func resolve(state: ReadAloudController.State, takeActive: Bool, isNarrow: Bool) -> NowReadingLayout {
        guard !takeActive else { return .hidden }
        switch state {
        case .idle, .noVoice: return .hidden
        case .preparing, .reading, .waiting, .paused: return isNarrow ? .compact : .full
        case .failed: return isNarrow ? .failedCompact : .failed
        }
    }
}

extension AppModel {
    var nowReadingLayout: NowReadingLayout {
        NowReadingLayout.resolve(state: readAloud.state, takeActive: recordingActive, isNarrow: windowIsNarrowForReading)
    }

    func openReading() async {
        guard let item = readAloud.item else { return }
        if item.entryID != Self.unsavedReadingID, selectedEntryID != item.entryID || !transcriptIsOnScreen {
            _ = try? await openEntry(item.entryID)
        }
        switch item.source {
        case .summary: setTranscriptPaneMode(.summary)
        case .transcript, .translation: setTranscriptPaneMode(.transcript)
        }
    }
}

/// Source, previous, pause/resume, skip, speed and stop for the reading in progress; a failed one offers Try Again instead.
struct NowReadingControl: View {
    let layout: NowReadingLayout

    @Environment(AppModel.self) private var model

    var body: some View {
        switch layout {
        case .hidden:
            EmptyView()
        case .full, .compact:
            transport
        case .failed, .failedCompact:
            failure
        }
    }

    private var controller: ReadAloudController { model.readAloud }
    private var isCompact: Bool { layout == .compact }

    private var sentenceValue: String {
        guard let item = controller.item else { return "" }
        return String(localized: "Sentence \(min(item.unitIndex + 1, item.unitCount)) of \(item.unitCount)")
    }

    private var transport: some View {
        let transport = model.readingTransport
        return HStack(spacing: DS.Spacing.snug) {
            sourceMenu
            Button { Task { await model.skipReading(by: -1) } } label: {
                Label("Previous Sentence", systemImage: "backward.end.fill")
            }
            .disabled(!transport.stepEnabled)
            .axLeaf("Toolbar.Button.ReadingBack")
            Button { Task { await model.toggleReading() } } label: {
                Label(
                    LocalizedStringKey(transport.toggle == .pause ? "Pause Reading" : "Resume Reading"),
                    systemImage: transport.toggle == .pause ? "pause.fill" : "play.fill"
                )
            }
            .disabled(!transport.toggleEnabled)
            .axLeaf("Toolbar.Button.ReadingPause")
            Button { Task { await model.skipReading(by: 1) } } label: {
                Label("Skip Sentence", systemImage: "forward.end.fill")
            }
            .disabled(!transport.stepEnabled)
            .axLeaf("Toolbar.Button.ReadingSkip")
            if !isCompact {
                speedMenu
            }
            Button { Task { await model.stopReading() } } label: {
                Label("Stop Reading", systemImage: "stop.fill")
            }
            .axLeaf("Toolbar.Button.ReadingStop")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, DS.Spacing.snug)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Reading")
        .accessibilityValue(sentenceValue)
        .axBranch("Toolbar.NowReading")
    }

    private var sourceMenu: some View {
        Menu {
            if let item = controller.item {
                Text(item.title)
            }
            Button("Open") { Task { await model.openReading() } }
                .axLeaf("Toolbar.MenuItem.ReadingOpen")
            if isCompact {
                Menu("Speed") { speedItems }
                    .axLeaf("Toolbar.MenuItem.ReadingSpeed")
            }
        } label: {
            Label(sourceTitle, systemImage: "speaker.wave.2.fill")
                .labelStyle(.titleAndIcon)
        } primaryAction: {
            Task { await model.openReading() }
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("Open what is being read")
        .axLeaf("Toolbar.Menu.ReadingSource")
    }

    private var sourceTitle: String {
        guard let item = controller.item else { return "" }
        let source = ReadAloudController.label(of: item.source)
        return item.voiceName.isEmpty ? source : "\(source) · \(item.voiceName)"
    }

    private var speedMenu: some View {
        Menu {
            speedItems
        } label: {
            Text(verbatim: Self.speedLabel(controller.speed))
                .monospacedDigit()
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Reading speed")
        .axLeaf("Toolbar.Menu.ReadingSpeed")
    }

    private var speedItems: some View {
        Picker("Speed", selection: Binding(get: { controller.speed }, set: { model.setReadingSpeed($0) })) {
            ForEach(ReadAloudController.speeds, id: \.self) { speed in
                Text(verbatim: Self.speedLabel(speed)).tag(speed)
            }
        }
        .pickerStyle(.inline)
    }

    static func speedLabel(_ speed: Double, locale: Locale = .current) -> String {
        "\(speed.formatted(.number.precision(.fractionLength(0...2)).locale(locale)))×"
    }

    @ViewBuilder
    private var failure: some View {
        let message = model.readAloud.failureMessage(named: controller.item?.voiceName ?? "")
        let blocked = model.readingBlockedReason != nil
        if layout == .failedCompact {
            Menu {
                Text(message)
                Button("Try Again") { Task { await model.retryReading() } }
                    .disabled(blocked)
                    .axLeaf("Toolbar.MenuItem.ReadingTryAgain")
                Button("Use Built-in Voice") { Task { await model.retryReadingWithBuiltInVoice() } }
                    .disabled(blocked)
                    .axLeaf("Toolbar.MenuItem.ReadingBuiltIn")
                Button("Stop Reading") { Task { await model.stopReading() } }
                    .axLeaf("Toolbar.MenuItem.ReadingStop")
            } label: {
                Label("Reading stopped", systemImage: "exclamationmark.triangle")
            }
            .fixedSize()
            .help(message)
            .axLeaf("Toolbar.Menu.ReadingFailed")
        } else {
            HStack(spacing: DS.Spacing.snug) {
                Image(systemName: "exclamationmark.triangle")
                    .accessibilityHidden(true)
                Text(message)
                    .lineLimit(1)
                    .axLeaf("Toolbar.Label.ReadingFailed")
                Button("Try Again") { Task { await model.retryReading() } }
                    .disabled(blocked)
                    .axLeaf("Toolbar.Button.ReadingTryAgain")
                Button("Use Built-in Voice") { Task { await model.retryReadingWithBuiltInVoice() } }
                    .disabled(blocked)
                    .axLeaf("Toolbar.Button.ReadingBuiltIn")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, DS.Spacing.snug)
        }
    }
}
