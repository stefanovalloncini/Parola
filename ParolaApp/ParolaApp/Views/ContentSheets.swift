import SwiftUI
import ParolaCore

struct ContentSheetsModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var meetingAppSnapshot: String = ""

    func body(content: Content) -> some View {
        @Bindable var model = model
        return content
            .sheet(isPresented: $model.youtubeSheetOpen) { YouTubeURLSheet() }
            .sheet(isPresented: $model.showingTrash) { MacRecentlyDeletedView() }
            .sheet(item: $model.promptOutput) { output in
                PromptOutputSheet(output: output)
            }
            .sheet(isPresented: $model.showingSpeakersSheet) {
                if let transcript = model.transcript {
                    SpeakersSheet(transcript: transcript)
                }
            }
            .onChange(of: model.meetingDetectedApp) { _, name in
                if let name { meetingAppSnapshot = name }
            }
            .alert(
                "\(meetingAppSnapshot) just launched",
                isPresented: meetingPromptBinding
            ) {
                Button("Record this meeting") { model.startMeetingRecording() }
                    .axLeaf("Meeting.Button.Record")
                Button("Not now", role: .cancel) { model.dismissMeetingPrompt() }
                    .axLeaf("Meeting.Button.NotNow")
            } message: {
                Text("Start a system-audio recording? The result lands in your library as a Meeting.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .parolaOpenEntry)) { note in
                if let id = note.userInfo?["id"] as? String {
                    model.selectedEntryID = id
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .parolaStartDictation)) { _ in
                model.startDictationFromIntent()
            }
            .onReceive(NotificationCenter.default.publisher(for: .parolaStopDictation)) { _ in
                model.stopDictationFromIntent()
            }
            .onReceive(NotificationCenter.default.publisher(for: .parolaStartRecording)) { _ in
                model.startRecording(source: .microphone)
            }
            .onReceive(NotificationCenter.default.publisher(for: .parolaSummarizeLast)) { _ in
                model.summarizeLatestEntry()
            }
    }

    private var meetingPromptBinding: Binding<Bool> {
        Binding(
            get: { model.meetingDetectedApp != nil },
            set: { if !$0 { model.dismissMeetingPrompt() } }
        )
    }
}

extension View {
    func contentSheets() -> some View {
        modifier(ContentSheetsModifier())
    }
}
