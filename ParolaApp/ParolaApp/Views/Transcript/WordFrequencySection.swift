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
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        HStack {
                            Text(entry.word)
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.primaryText)
                            Spacer()
                            Text("\(entry.count)")
                                .font(DS.Font.caption.monospacedDigit())
                                .foregroundStyle(DS.Color.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(DS.Color.accent.opacity(0.10))
                                )
                        }
                    }
                }
            }
        }
    }
}
