import SwiftUI
import ParolaCore

struct WordFrequencySection: View {
    @EnvironmentObject var model: AppModel

    private var entries: [WordFrequency.Entry] {
        guard let text = model.transcript?.text else { return [] }
        return WordFrequency.compute(text: text, limit: 12)
    }

    var body: some View {
        if !entries.isEmpty {
            InfoSection(title: "Top words") {
                let maxCount = entries.first?.count ?? 1
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entries) { entry in
                        WordFrequencyBar(
                            word: entry.word,
                            count: entry.count,
                            fraction: Double(entry.count) / Double(max(1, maxCount))
                        )
                    }
                }
            }
        }
    }
}

private struct WordFrequencyBar: View {
    let word: String
    let count: Int
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(word)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.primaryText)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DS.Color.accent.opacity(0.10))
                    Capsule()
                        .fill(DS.Color.accent.opacity(0.55))
                        .frame(width: max(2, proxy.size.width * fraction))
                }
            }
            .frame(height: 8)
            Text("\(count)")
                .font(DS.Font.captionMono)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }
}
