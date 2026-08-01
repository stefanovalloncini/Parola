import SwiftUI
import ParolaCore

struct SpeakerStatsSection: View {
    let stats: [SpeakerStats]

    var body: some View {
        if !stats.isEmpty {
            InfoSection(title: "Speakers · \(stats.count)") {
                ForEach(stats) { row in
                    StatRow(stats: row)
                }
            }
        }
    }
}

private struct StatRow: View {
    let stats: SpeakerStats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(DS.speakerColor(for: stats.speaker))
                    .frame(width: 8, height: 8)
                Text(stats.speaker)
                    .font(DS.Font.body.weight(.medium))
                Spacer()
                Text("\(Int((stats.share * 100).rounded()))%")
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(DS.Color.secondaryText)
            }
            HStack(spacing: 12) {
                Label("\(stats.wordCount)", systemImage: "text.word.spacing")
                Label("\(stats.characterCount)", systemImage: "character")
                Label(durationLabel, systemImage: "clock")
            }
            .font(DS.Font.caption.monospacedDigit())
            .foregroundStyle(DS.Color.secondaryText)
            .labelStyle(.titleAndIcon)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var durationLabel: String {
        Timecode.format(stats.durationSeconds.rounded())
    }
}
