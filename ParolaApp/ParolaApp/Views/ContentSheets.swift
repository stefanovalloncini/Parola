import SwiftUI
import ParolaCore

struct ContentSheetsModifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var showingTrash: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.youtubeSheetOpen) { YouTubeURLSheet() }
            .sheet(isPresented: $showingTrash) { MacRecentlyDeletedView() }
            .sheet(item: $model.promptOutput) { output in
                PromptOutputSheet(output: output)
            }
            .sheet(isPresented: $model.showingSpeakersSheet) {
                if let transcript = model.transcript {
                    SpeakersSheet(transcript: transcript)
                }
            }
            .alert(
                "\(model.meetingDetectedApp ?? "") just launched",
                isPresented: Binding(
                    get: { model.meetingDetectedApp != nil },
                    set: { if !$0 { model.dismissMeetingPrompt() } }
                )
            ) {
                Button("Record this meeting") { model.startMeetingRecording() }
                Button("Not now", role: .cancel) { model.dismissMeetingPrompt() }
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
}

extension View {
    func contentSheets(showingTrash: Binding<Bool>) -> some View {
        modifier(ContentSheetsModifier(showingTrash: showingTrash))
    }
}
