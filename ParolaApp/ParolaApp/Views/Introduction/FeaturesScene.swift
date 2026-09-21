import SwiftUI
import ParolaCore

struct FeaturesScene: View {
    @Environment(AppModel.self) private var model

    static func rows(features: FeatureSet) -> [FeatureRow.Item] {
        var items = [
            FeatureRow.Item(
                symbol: DS.categorySymbol(for: .transcription),
                title: features.isEnabled(.youtube) ? "Transcribe files and links" : "Transcribe files",
                line: features.isEnabled(.youtube)
                    ? "Drop audio or video, or paste a YouTube link."
                    : "Drop audio or video files."
            )
        ]
        if features.isEnabled(.meetings) {
            items.append(FeatureRow.Item(
                symbol: DS.categorySymbol(for: .meeting),
                title: "Record meetings",
                line: "Offers to record when a meeting app opens."
            ))
        }
        if features.isEnabled(.dictation) {
            items.append(FeatureRow.Item(
                symbol: DS.categorySymbol(for: .dictation),
                title: "Dictate in any app",
                line: "Hold a key and speak. The words land where you type."
            ))
        }
        if features.isEnabled(.liveCaptions) {
            items.append(FeatureRow.Item(
                symbol: "captions.bubble.fill",
                title: "Live captions",
                line: "Your words as subtitles, in a panel that stays on top."
            ))
        }
        return items
    }

    /// Two cards to a row, in order; an odd last card sits alone in the last row.
    static func arrangement(count: Int) -> [[Int]] {
        stride(from: 0, to: max(0, count), by: 2).map { start in
            Array(start..<min(start + 2, count))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            Text("What it does.")
                .font(DS.Font.hero)
                .foregroundStyle(DS.Color.primaryText)
                .sceneEntrance(order: 0)
            grid
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var grid: some View {
        let items = Self.rows(features: model.features)
        let hotkeyName = HotkeyDisplay.description(
            keyCode: model.dictationKeyCode,
            modifiers: model.dictationModifierFlags
        )
        return VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            ForEach(Self.arrangement(count: items.count), id: \.self) { indices in
                HStack(alignment: .top, spacing: DS.Spacing.medium) {
                    ForEach(indices, id: \.self) { index in
                        FeatureCard(item: items[index], hotkeyName: hotkeyName)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .sceneEntrance(order: 2 + index)
                    }
                    if indices.count == 1 {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: 0)
                            .allowsHitTesting(false)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FeatureRow: View {
    struct Item: Identifiable, Equatable {
        let symbol: String
        let title: LocalizedStringKey
        let line: LocalizedStringKey
        var id: String { symbol }
    }

    let item: Item

    @ScaledMetric(relativeTo: .title) private var glyphSize: CGFloat = 26
    // 36, not the glyph's 26: `person.2` draws 35 pt of ink at that point size and a narrower box lets it overhang the title.
    @ScaledMetric(relativeTo: .title) private var glyphBox: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.small) {
            Image(systemName: item.symbol)
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(DS.Color.accent)
                .frame(width: glyphBox, height: 30, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                Text(item.title)
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                Text(item.line)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
