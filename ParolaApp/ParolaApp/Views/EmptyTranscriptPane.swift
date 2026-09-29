import SwiftUI

struct EmptyTranscriptPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.transcriptIsUntranscribed {
                EmptyStateView(
                    systemImage: "waveform",
                    title: "Not Transcribed",
                    message: "This recording is in your library, but it hasn't been transcribed yet."
                ) {
                    Button("Transcribe") { model.transcribeLoadedEntry() }
                        .buttonStyle(DSPillButtonStyle(kind: .primary))
                        .disabled(!model.canRetranscribeSelectedEntry || model.retranscribeRequest != nil)
                        .axLeaf("Transcript.Button.Transcribe")
                }
            } else {
                EmptyStateView(
                    systemImage: "waveform.slash",
                    title: "No Speech Detected",
                    message: "Parola didn't find any speech in this audio."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
