import SwiftUI
import ParolaCore

struct FeaturesScene: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

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
                line: "Records the call when a meeting starts."
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
                line: "Subtitles for anything playing on your Mac."
            ))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            Text("What it does.")
                .font(DS.Font.hero)
                .foregroundStyle(DS.Color.primaryText)
            VStack(alignment: .leading, spacing: DS.Spacing.medium) {
                ForEach(Array(Self.rows(features: model.features).enumerated()), id: \.element.id) { index, item in
                    FeatureRow(item: item)
                        .opacity(isShown ? 1 : 0)
                        .offset(x: isShown ? 0 : -32)
                        .animation(entrance(row: index), value: hasAppeared)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { hasAppeared = true }
    }

    private var isShown: Bool { hasAppeared || reduceMotion }

    private func entrance(row: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.5, dampingFraction: 0.85).delay(Double(row) * 0.08)
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

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.small) {
            Image(systemName: item.symbol)
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(DS.Color.accent)
                .frame(width: 44, height: 30, alignment: .leading)
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
