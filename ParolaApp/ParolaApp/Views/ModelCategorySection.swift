import SwiftUI

struct ModelsCategory: Identifiable {
    let id: String
    let title: String
    let description: String
    let symbol: String
    let tint: Color

    static let all: [ModelsCategory] = [
        .init(
            id: "apple-speech",
            title: "Apple Speech",
            description: "On-device speech recognition built into macOS.",
            symbol: "waveform.and.mic",
            tint: .secondary
        ),
        .init(
            id: "language-specific",
            title: "Language Specific",
            description: "Models tuned for a single language.",
            symbol: "character.book.closed",
            tint: .blue
        ),
        .init(
            id: "whisperkit",
            title: "WhisperKit",
            description: "OpenAI Whisper compiled to Core ML.",
            symbol: "waveform",
            tint: DS.Color.accent
        ),
        .init(
            id: "whisper-cpp",
            title: "Whisper C++",
            description: "Compact Whisper builds from the whisper.cpp project.",
            symbol: "chevron.left.forwardslash.chevron.right",
            tint: .purple
        ),
        .init(
            id: "pro",
            title: "Pro",
            description: "Higher-accuracy variants for longer recordings.",
            symbol: "star.fill",
            tint: .orange
        ),
        .init(
            id: "speaker-recognition",
            title: "Speaker Recognition",
            description: "Identify and label distinct speakers.",
            symbol: "person.2.wave.2",
            tint: .green
        )
    ]
}

struct ModelCategorySection: View {
    let categories: [ModelsCategory]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                Button { } label: {
                    ModelCategoryRow(category: category)
                }
                .buttonStyle(.plain)
                if index < categories.count - 1 {
                    Divider().padding(.leading, 56)
                }
            }
        }
        .background(DS.Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ModelCategoryRow: View {
    let category: ModelsCategory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: category.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(category.tint)
                .frame(width: 28, height: 28)
                .background(category.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.headline)
                Text(category.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
