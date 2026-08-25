import SwiftUI

struct EmptyTranscriptPane: View {
    var body: some View {
        EmptyStateView(
            systemImage: "waveform.slash",
            title: "No Speech Detected",
            message: "Parola didn't find any speech in this audio."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
