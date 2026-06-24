import SwiftUI
import ParolaCore

struct WordFrequencySection: View {
    @Environment(AppModel.self) private var model

    private var entries: [WordFrequency.Entry] {
        guard let text = model.transcript?.text else { return [] }
        let stopWords = WordFrequency.stopWords(for: model.transcript?.language)
        return WordFrequency.compute(text: text, limit: 12, stopWords: stopWords)
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
                        ) {
                            model.findQuery = entry.word
                            if !model.findIsOpen { model.toggleFind() }
                        }
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
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
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
                            .fill(DS.Color.accent.opacity(hovering ? 0.75 : 0.55))
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Find “\(word)” in transcript")
        .axLeaf("WordFrequency.Button.FindWord")
    }
}
