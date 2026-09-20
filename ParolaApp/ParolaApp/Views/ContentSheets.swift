import SwiftUI
import ParolaCore

struct ContentSheetsModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var meetingAppSnapshot: String = ""

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
            .sheet(item: $model.exportOptionsFormat) { format in
                ExportOptionsSheet(format: format)
            }
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
                Button(checkpoint.kind == .recording ? "Discard" : "Not Now", role: .cancel) { model.declinePendingRecovery() }
                    .axLeaf("Recovery.Button.Decline")
            } message: { checkpoint in
                switch checkpoint.kind {
                case .recording:
                    Text("Parola quit while recording. Restore puts the transcript captured up to that point in your library.")
                case .fileTranscription:
                    Text("Parola quit while transcribing \(checkpoint.sourceURL?.lastPathComponent ?? "this file").")
                }
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
        case .recording: String(localized: "Restore recovered recording?")
        case .fileTranscription: String(localized: "Transcribe \(model.pendingRecovery?.sourceURL?.lastPathComponent ?? "the file") again?")
        case nil: ""
        }
    }

    // Dismissing without choosing counts as a decline, so the file can't be re-offered forever.
    private var recoveryBinding: Binding<Bool> {
        Binding(
            get: { model.pendingRecovery != nil },
            set: { if !$0 { model.declinePendingRecovery() } }
        )
    }
}

extension View {
    func contentSheets() -> some View {
        modifier(ContentSheetsModifier())
    }
}
