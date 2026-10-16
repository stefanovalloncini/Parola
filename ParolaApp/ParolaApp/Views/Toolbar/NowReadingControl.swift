import SwiftUI
import ParolaCore

/// How much toolbar room the window leaves: the control grows with it.
enum NowReadingWidth: Equatable {
    case narrow
    case medium
    case wide

    static let mediumFrom: CGFloat = 1200
    static let wideFrom: CGFloat = 1600

    static func tier(for width: CGFloat) -> NowReadingWidth {
        width >= wideFrom ? .wide : width >= mediumFrom ? .medium : .narrow
    }
}

/// What the Now Reading item shows for a reading's state, whether a take runs, and how wide the window is.
enum NowReadingLayout: Equatable {
    case hidden
    case full
    case compact
    case minimal
    case failed

    static func resolve(state: ReadAloudController.State, takeActive: Bool, width: NowReadingWidth) -> NowReadingLayout {
        guard !takeActive else { return .hidden }
        switch state {
        case .idle, .noVoice: return .hidden
        case .preparing, .reading, .waiting, .paused:
            switch width {
            case .wide: return .full
            case .medium: return .compact
            case .narrow: return .minimal
            }
        case .failed: return .failed
        }
    }
}

extension AppModel {
    /// On a narrow window the transcript toolbar has no room for another item, so the read button's menu carries the controls.
    var nowReadingLayout: NowReadingLayout {
        let layout = NowReadingLayout.resolve(state: readAloud.state, takeActive: recordingActive, width: windowWidthTierForReading)
        return layout == .minimal && transcriptToolbarShows ? .hidden : layout
    }

    var readButtonCarriesTransport: Bool {
        windowWidthTierForReading == .narrow && transcriptToolbarShows && nowReadingLayout == .hidden
            && !recordingActive && readAloud.item != nil
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
        case .minimal:
            minimal
        case .failed:
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
        let blocked = transport.blockedMessage
        return HStack(spacing: isCompact ? DS.Spacing.hair : DS.Spacing.snug) {
            sourceMenu
            Button { Task { await model.skipReading(by: -1) } } label: {
                Label("Previous Sentence", systemImage: "backward.end.fill")
            }
            .disabled(!transport.stepEnabled)
            .help(blocked.map { Text($0) } ?? Text("Previous Sentence"))
            .axLeaf("Toolbar.Button.ReadingBack")
            Button { Task { await model.toggleReading() } } label: {
                Label(
                    LocalizedStringKey(transport.toggle == .pause ? "Pause Reading" : "Resume Reading"),
                    systemImage: transport.toggle == .pause ? "pause.fill" : "play.fill"
                )
            }
            .disabled(!transport.toggleEnabled)
            .help(blocked.map { Text($0) } ?? Text(LocalizedStringKey(transport.toggle == .pause ? "Pause Reading" : "Resume Reading")))
            .axLeaf("Toolbar.Button.ReadingPause")
            Button { Task { await model.skipReading(by: 1) } } label: {
                Label("Skip Sentence", systemImage: "forward.end.fill")
            }
            .disabled(!transport.stepEnabled)
            .help(blocked.map { Text($0) } ?? Text("Skip Sentence"))
            .axLeaf("Toolbar.Button.ReadingSkip")
            if !isCompact {
                speedMenu
            }
            Button { Task { await model.stopReading() } } label: {
                Label("Stop Reading", systemImage: "stop.fill")
            }
            .help("Stop Reading")
            .axLeaf("Toolbar.Button.ReadingStop")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.horizontal, isCompact ? 0 : DS.Spacing.snug)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Reading")
        .accessibilityValue(sentenceValue)
        .axBranch("Toolbar.NowReading")
    }

    private var minimal: some View {
        let transport = model.readingTransport
        return Menu {
            if let item = controller.item {
                Text(item.title)
                Text(sourceTitle)
            }
            Button("Open") { Task { await model.openReading() } }
                .axLeaf("Toolbar.MenuItem.ReadingOpen")
            Divider()
            Button(LocalizedStringKey(transport.toggle == .pause ? "Pause Reading" : "Resume Reading")) {
                Task { await model.toggleReading() }
            }
            .disabled(!transport.toggleEnabled)
            .axLeaf("Toolbar.MenuItem.ReadingPause")
            Button("Previous Sentence") { Task { await model.skipReading(by: -1) } }
                .disabled(!transport.stepEnabled)
                .axLeaf("Toolbar.MenuItem.ReadingBack")
            Button("Skip Sentence") { Task { await model.skipReading(by: 1) } }
                .disabled(!transport.stepEnabled)
                .axLeaf("Toolbar.MenuItem.ReadingSkip")
            Menu("Speed") { speedItems }
                .axLeaf("Toolbar.MenuItem.ReadingSpeed")
            Button("Stop Reading") { Task { await model.stopReading() } }
                .axLeaf("Toolbar.MenuItem.ReadingStop")
        } label: {
            Image(systemName: transport.toggle == .pause ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .imageScale(.small)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(transport.blockedMessage.map { Text($0) } ?? Text("Now Reading"))
        .accessibilityLabel("Now Reading")
        .accessibilityValue(sentenceValue)
        .axLeaf("Toolbar.Menu.ReadingMinimal")
    }

    private var sourceMenu: some View {
        Menu {
            if let item = controller.item {
                Text(item.title)
                Text(sourceTitle)
            }
            Button("Open") { Task { await model.openReading() } }
                .axLeaf("Toolbar.MenuItem.ReadingOpen")
            if isCompact {
                Menu("Speed") { speedItems }
                    .axLeaf("Toolbar.MenuItem.ReadingSpeed")
            }
        } label: {
            if isCompact {
                Image(systemName: "speaker.wave.2.fill")
            } else {
                Label(sourceTitle, systemImage: "speaker.wave.2.fill")
                    .labelStyle(.titleAndIcon)
            }
        } primaryAction: {
            Task { await model.openReading() }
        }
        .menuIndicator(isCompact ? .hidden : .visible)
        .fixedSize()
        .help("Show the text being read")
        .accessibilityLabel(sourceTitle)
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
                .foregroundStyle(.primary)
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
        if case .failed(let line) = controller.state {
            let blocked = model.readingBlockedReason != nil
            Menu {
                Text(line)
                Button("Try Again") { Task { await model.retryReading() } }
                    .disabled(blocked)
                    .axLeaf("Toolbar.MenuItem.ReadingTryAgain")
                if controller.canUseBuiltInVoice {
                    Button("Use Built-in Voice") { Task { await model.retryReadingWithBuiltInVoice() } }
                        .disabled(blocked)
                        .axLeaf("Toolbar.MenuItem.ReadingBuiltIn")
                }
                Button("Stop Reading") { Task { await model.stopReading() } }
                    .axLeaf("Toolbar.MenuItem.ReadingStop")
            } label: {
                Image(systemName: "exclamationmark.triangle")
            }
            .fixedSize()
            .help(line)
            .accessibilityLabel(line)
            .axLeaf("Toolbar.Menu.ReadingFailed")
        }
    }
}
