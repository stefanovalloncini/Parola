import SwiftUI
import ParolaCore

struct ContentSheetsModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var meetingAppSnapshot: String = ""
    @State private var confirmingRecoveryDiscard = false

    func body(content: Content) -> some View {
        @Bindable var model = model
        return content
            .sheet(isPresented: $model.youtubeSheetOpen) { YouTubeURLSheet() }
            .sheet(item: $model.duplicateImport) { pending in
                DuplicateImportSheet(pending: pending)
            }
            .sheet(item: $model.promptOutput) { output in
                PromptOutputSheet(output: output)
            }
            .sheet(isPresented: $model.showingSpeakersSheet) {
                if let transcript = model.transcript {
                    SpeakersSheet(transcript: transcript)
                }
            }
            .sheet(item: $model.editingSegmentNote) { target in
                SegmentNoteSheet(target: target)
            }
            .sheet(isPresented: $model.showingPeopleSheet) { ManagePeopleSheet() }
            .sheet(isPresented: $model.exportSheetOpen) { ExportSheet() }
            .sheet(isPresented: $model.burnSheetOpen) { BurnStyleSheet() }
            .onChange(of: model.meetingDetectedApp, initial: true) { _, name in
                if let name { meetingAppSnapshot = name }
            }
            .alert(
                "\(meetingAppSnapshot) is running",
                isPresented: meetingPromptBinding
            ) {
                Button("Record This Meeting") { model.startMeetingRecording() }
                    .axLeaf("Meeting.Button.Record")
                Button("Not Now", role: .cancel) { model.dismissMeetingPrompt() }
                    .axLeaf("Meeting.Button.NotNow")
            } message: {
                Text("Start a system-audio recording? The result lands in your library as a Meeting.")
            }
            .alert(
                recoveryTitle,
                isPresented: recoveryBinding,
                presenting: model.pendingRecovery
            ) { checkpoint in
                Button(checkpoint.kind == .recording ? "Restore" : "Transcribe") { model.acceptPendingRecovery() }
                    .axLeaf("Recovery.Button.Accept")
                Button("Not Now", role: .cancel) { model.declinePendingRecovery() }
                    .axLeaf("Recovery.Button.Decline")
                if checkpoint.isTake {
                    Button("Discard…", role: .destructive) { confirmingRecoveryDiscard = true }
                        .axLeaf("Recovery.Button.Discard")
                }
            } message: { checkpoint in
                switch checkpoint.kind {
                case .recording, .micTrack:
                    Text("Parola quit while recording. Restore opens what was captured; Not Now saves it to your library for later.")
                case .fileTranscription where checkpoint.isTake:
                    Text("Parola quit while transcribing \(checkpoint.sourceName ?? "this recording"). Not Now saves the recording to your library without a transcript.")
                case .fileTranscription:
                    Text("Parola quit while transcribing \(checkpoint.sourceName ?? "this file").")
                }
            }
            .alert(
                retranscribeTitle,
                isPresented: Binding(
                    get: { model.pendingRetranscribe != nil },
                    set: { if !$0 { model.pendingRetranscribe = nil } }
                ),
                presenting: model.pendingRetranscribe
            ) { _ in
                Button("Cancel", role: .cancel) { model.pendingRetranscribe = nil }
                    .axLeaf("Alert.Button.RetranscribeCancel")
                Button("Transcribe Again") { model.confirmTranscribeAgain() }
                    .axLeaf("Alert.Button.RetranscribeConfirm")
            } message: { ask in
                Text(verbatim: Self.retranscribeMessage(for: ask))
            }
            .alert("Discard this recording?", isPresented: $confirmingRecoveryDiscard) {
                // Return keeps the take: only a deliberate click deletes it.
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
                    .axLeaf("Recovery.Button.KeepOffer")
                Button("Discard", role: .destructive) { model.discardPendingRecovery() }
                    .axLeaf("Recovery.Button.ConfirmDiscard")
            } message: {
                Text("It won't be saved to your library, and this can't be undone.")
            }
    }

    private var meetingPromptBinding: Binding<Bool> {
        Binding(
            get: { model.meetingDetectedApp != nil },
            set: { if !$0 { model.dismissMeetingPrompt() } }
        )
    }

    private var recoveryTitle: String {
        switch model.pendingRecovery?.kind {
        case .recording, .micTrack: String(localized: "Restore recovered recording?")
        case .fileTranscription: String(localized: "Transcribe \(model.pendingRecovery?.sourceName ?? "the file") again?")
        case nil: ""
        }
    }

    private var retranscribeTitle: String {
        guard let ask = model.pendingRetranscribe else { return "" }
        return String(localized: "Transcribe again with \(ask.choiceLabel)?")
    }

    static func retranscribeMessage(for ask: RetranscribeAsk) -> String {
        let replaced = String(localized: "The current transcript, its favorites, notes, summary and translation will be replaced.")
        guard let substitute = ask.substituteModelLabel else { return replaced }
        let fallback = String(localized: "This transcript's own model isn't available, so Parola will run \(substitute).")
        return replaced + "\n\n" + fallback
    }

    // Every answer is a button of its own; a prompt closed without one stays on offer and deletes nothing. It waits out a take.
    private var recoveryBinding: Binding<Bool> {
        Binding(
            get: { model.pendingRecovery != nil && !confirmingRecoveryDiscard && !model.recordingActive },
            set: { _ in }
        )
    }
}

extension View {
    func contentSheets() -> some View {
        modifier(ContentSheetsModifier())
    }
}
