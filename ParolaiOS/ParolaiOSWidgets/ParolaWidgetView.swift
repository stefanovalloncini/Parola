import AppIntents
import ParolaCore
import SwiftUI
import WidgetKit

struct ParolaWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            small
        default:
            medium
        }
    }

    private var small: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.title)
                .foregroundStyle(.tint)
            Text("Parola")
                .font(.headline)
            Button(intent: StartRecordingIntent()) {
                Label("Record", systemImage: "mic.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.accentColor)
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var medium: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Parola")
                    .font(.headline)
                Text("On-device transcripts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 6) {
                Button(intent: StartRecordingIntent()) {
                    Label("Record", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                Button(intent: OpenLastTranscriptIntent()) {
                    Label("Open Last", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
