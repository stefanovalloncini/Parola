import SwiftUI

struct EmptyTranscriptPane: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Speech Detected", systemImage: "waveform.slash")
        } description: {
            Text("Parola didn't find any speech in this audio.")
        }
    }
}
