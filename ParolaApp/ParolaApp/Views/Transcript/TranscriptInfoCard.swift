import SwiftUI
import ParolaCore

struct TranscriptInfoCard: View {
    let transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.tight) {
            row("Language", value: transcript.language.uppercased())
            row("Model", value: transcript.modelName)
            row("Segments", value: "\(transcript.segments.count)")
            if let d = transcript.durationSeconds {
                row("Duration", value: Duration.seconds(d).formatted(.time(pattern: .hourMinuteSecond)))
            }
        }
        .padding(DS.Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
        .font(.callout)
    }
}
