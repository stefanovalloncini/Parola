import SwiftUI

struct EmptyTranscriptPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TranscriptTitleHeading()
                .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
                .padding([.horizontal, .top], DS.Spacing.large)
                .frame(maxWidth: .infinity)
            state
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var state: some View {
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
}
