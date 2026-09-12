import SwiftUI

struct ModelsCategory: Identifiable {
    let id: String
    let title: String
    let description: String
    let symbol: String
    let tint: Color

    // Only the engine families the catalog actually ships — this list must not drift
    // from ModelCatalog (a "Whisper C++" row once advertised models the app never had).
    static let all: [ModelsCategory] = [
        .init(
            id: "apple-speech",
            title: "Apple Speech",
            description: "On-device speech recognition built into macOS. Nothing to download.",
            symbol: "waveform.and.mic",
            tint: .secondary
        ),
        .init(
            id: "whisperkit",
            title: "WhisperKit",
            description: "OpenAI Whisper compiled to Core ML. Multilingual, can translate to English.",
            symbol: "waveform",
            tint: .teal
        ),
        .init(
            id: "parakeet",
            title: "Parakeet",
            description: "NVIDIA Parakeet via FluidAudio. Fast, English only.",
            symbol: "bird",
            tint: .green
        )
    ]
}

struct ModelCategorySection: View {
    let categories: [ModelsCategory]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(categories) { category in
                ModelCategoryRow(category: category)
                if category.id != categories.last?.id {
                    Divider().padding(.leading, 56)
                }
            }
        }
        .background(DS.Color.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
    }
}

struct ModelCategoryRow: View {
    let category: ModelsCategory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: category.symbol)
                .font(DS.Font.heading)
                .foregroundStyle(category.tint)
                .frame(width: 28, height: 28)
                .background(category.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(DS.Font.heading)
                Text(category.description)
                    .font(DS.Font.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
