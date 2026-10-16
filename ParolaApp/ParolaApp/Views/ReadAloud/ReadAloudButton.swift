import SwiftUI
import ParolaCore

/// What the read button shows and does for the reading's state, the entry it is on and the recording around it.
struct ReadAloudButtonStatus: Equatable {
    enum Action: Equatable {
        case start
        case pause
        case resume
        case retry
        case none
    }

    var action: Action
    var symbol: String
    var titleKey: String
    var isEnabled: Bool
    var blockedMessage: String?
    var failureMessage: String?

    static func resolve(
        state: ReadAloudController.State,
        readsThis: Bool,
        blocked: ReadAloudController.BlockedReason?,
        hasContent: Bool
    ) -> ReadAloudButtonStatus {
        let effective: ReadAloudController.State = readsThis ? state : .idle
        let action: Action
        let symbol: String
        let key: String
        var failure: String?
        switch effective {
        case .reading:
            (action, symbol, key) = (.pause, "speaker.wave.2.fill", "Pause reading")
        case .paused, .waiting:
            (action, symbol, key) = (.resume, "speaker.wave.2.fill", "Resume reading")
        case .preparing:
            (action, symbol, key) = (.none, "speaker.wave.2.fill", "Preparing…")
        case .failed(let message):
            (action, symbol, key) = (.retry, "speaker.wave.2", "Try again")
            failure = message
        case .idle, .noVoice:
            (action, symbol, key) = (.start, "speaker.wave.2", "Read aloud")
        }
        let needsFreeOutput = action == .start || action == .resume || action == .retry
        let isBlocked = needsFreeOutput && blocked != nil
        return ReadAloudButtonStatus(
            action: action,
            symbol: symbol,
            titleKey: key,
            isEnabled: action != .none && !isBlocked && (hasContent || action == .pause || action == .resume),
            blockedMessage: isBlocked ? blocked?.message : nil,
            failureMessage: failure
        )
    }
}

/// Reads what the pane shows: the transcript, or the summary. The Chat pane has nothing to read.
struct ReadAloudButton: View {
    let source: AppModel.TranscriptPaneMode

    @Environment(AppModel.self) private var model

    var body: some View {
        if let kind {
            let status = self.status(for: kind)
            Menu {
                menuItems(kind: kind)
            } label: {
                Label(LocalizedStringKey(status.titleKey), systemImage: status.symbol)
            } primaryAction: {
                if status.isEnabled { perform(status.action, kind: kind) }
            }
            .disabled(!status.isEnabled && status.action != .none && model.readAloud.item == nil)
            .help((status.blockedMessage ?? status.failureMessage).map { Text($0) } ?? Text(LocalizedStringKey(status.titleKey)))
            .axLeaf("Toolbar.Transcript.Button.ReadAloud")
        }
    }

    private var kind: ReadAloudRequest.Kind? {
        switch source {
        case .transcript: .transcript
        case .summary: .summary
        case .chat: nil
        }
    }

    private var entryID: String {
        model.selectedEntryID ?? AppModel.unsavedReadingID
    }

    private func status(for kind: ReadAloudRequest.Kind) -> ReadAloudButtonStatus {
        ReadAloudButtonStatus.resolve(
            state: model.readAloud.state,
            readsThis: model.readAloud.reads(entryID: entryID, inPane: kind),
            blocked: model.readingBlockedReason,
            hasContent: hasContent(kind)
        )
    }

    private func hasContent(_ kind: ReadAloudRequest.Kind) -> Bool {
        switch kind {
        case .transcript, .translation: model.hasTranscript && !model.transcriptIsEmpty
        case .summary: model.transcript?.summary != nil
        }
    }

    private func perform(_ action: ReadAloudButtonStatus.Action, kind: ReadAloudRequest.Kind) {
        switch action {
        case .start: Task { await model.readAloud(ReadAloudRequest(kind: kind)) }
        case .pause: Task { await model.pauseReading() }
        case .resume: Task { await model.resumeReading() }
        case .retry: Task { await model.retryReading() }
        case .none: break
        }
    }

    @ViewBuilder
    private func menuItems(kind: ReadAloudRequest.Kind) -> some View {
        let blocked = model.readingBlockedReason != nil
        if let failure = status(for: kind).failureMessage {
            Button(failure) {}
                .disabled(true)
                .axLeaf("Toolbar.Transcript.MenuItem.FailureReason")
            Button("Try Again") { Task { await model.retryReading() } }
                .disabled(blocked)
                .axLeaf("Toolbar.Transcript.MenuItem.TryAgain")
            Divider()
        }
        if kind == .transcript {
            if let target = model.transcript?.translation?.targetLanguage {
                Button("Read Translation (\(LanguageDisplay.midSentenceName(for: target) ?? target))") {
                    Task { await model.readAloud(ReadAloudRequest(kind: .translation)) }
                }
                .disabled(blocked)
                .axLeaf("Translation.Button.ReadAloud")
            }
            Button("Read from Current Segment") {
                Task { await model.readAloud(ReadAloudRequest(kind: .transcript, fromSegment: model.currentSegmentID)) }
            }
            .disabled(blocked || model.currentSegmentID == nil)
            .axLeaf("Toolbar.Transcript.MenuItem.ReadFromCurrentSegment")
        }
        if model.readButtonCarriesTransport {
            transportItems
        }
        Button("Choose Voice…") { model.presentVoiceChooser(for: kind) }
            .disabled(!hasContent(kind))
            .axLeaf("Toolbar.Transcript.MenuItem.ChooseVoice")
        Button("Stop Reading") { Task { await model.stopReading() } }
            .disabled(model.readAloud.item == nil)
            .axLeaf("Toolbar.Transcript.MenuItem.StopReading")
    }

    @ViewBuilder
    private var transportItems: some View {
        let transport = model.readingTransport
        Button("Previous Sentence") { Task { await model.skipReading(by: -1) } }
            .disabled(!transport.stepEnabled)
            .help(transport.blockedMessage ?? "")
            .axLeaf("Toolbar.Transcript.MenuItem.ReadingBack")
        Button("Skip Sentence") { Task { await model.skipReading(by: 1) } }
            .disabled(!transport.stepEnabled)
            .help(transport.blockedMessage ?? "")
            .axLeaf("Toolbar.Transcript.MenuItem.ReadingSkip")
        Picker("Speed", selection: Binding(get: { model.readAloud.speed }, set: { model.setReadingSpeed($0) })) {
            ForEach(ReadAloudController.speeds, id: \.self) { speed in
                Text(verbatim: NowReadingControl.speedLabel(speed)).tag(speed)
            }
        }
        .pickerStyle(.menu)
        .axLeaf("Toolbar.Transcript.MenuItem.ReadingSpeed")
        Divider()
    }
}
