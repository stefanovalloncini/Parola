import SwiftUI
import ParolaCore

struct ModelsSettingsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                downloadedSection
                recommendedSection
                categoriesSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Color.surface)
        .onAppear { model.refreshModelList() }
    }

    // MARK: - Downloaded

    private var downloadedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Downloaded", count: installedVariants.count)
            if installedVariants.isEmpty {
                emptyDownloaded
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(installedVariants) { variant in
                        ModelCard(
                            variant: variant,
                            kind: model.selectedModel == variant.id ? .active : .installed,
                            primaryAction: { model.selectedModel = variant.id }
                        )
                    }
                }
            }
        }
    }

    private var emptyDownloaded: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
            Text("No models on disk yet. Pick one from Recommended below.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(DS.Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Recommended

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Recommended Models", count: recommendedVariants.count)
            LazyVStack(spacing: 10) {
                ForEach(recommendedVariants) { variant in
                    ModelCard(
                        variant: variant,
                        kind: downloadKind(for: variant),
                        primaryAction: { model.downloadModel(variant.id) }
                    )
                }
            }
        }
    }

    private func downloadKind(for variant: ModelVariant) -> ModelCard.Kind {
        if case .downloadingModel(let name, let progress) = model.phase, name == variant.id {
            return .downloading(progress: progress)
        }
        return .available
    }

    // MARK: - Categories

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Categories", count: nil)
            VStack(spacing: 0) {
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                    Button { } label: {
                        CategoryRow(category: category)
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

    // MARK: - Data

    private var installedVariants: [ModelVariant] {
        let installedIDs = Set(model.availableModels.filter(\.isInstalled).map(\.name))
        return ModelCatalog.all.filter { installedIDs.contains($0.id) }
    }

    private var recommendedVariants: [ModelVariant] {
        let installedIDs = Set(model.availableModels.filter(\.isInstalled).map(\.name))
        return ModelCatalog.all.filter { !installedIDs.contains($0.id) }
    }

    private var categories: [ModelsCategory] {
        ModelsCategory.all
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            if let count, count > 0 {
                Text("\(count)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Model card

private struct ModelCard: View {
    enum Kind {
        case active
        case installed
        case available
        case downloading(progress: Double)
    }

    let variant: ModelVariant
    let kind: Kind
    let primaryAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            iconTile
            VStack(alignment: .leading, spacing: 6) {
                Text(variant.displayName)
                    .font(.headline)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips) { chip in
                            TagChip(label: chip.label, color: chip.color)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(14)
        .background(DS.Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(iconTint.opacity(0.15))
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconTint)
        }
        .frame(width: 34, height: 34)
    }

    @ViewBuilder
    private var trailing: some View {
        switch kind {
        case .active:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(DS.Color.accent)
                .accessibilityLabel("Active model")
        case .installed:
            Button(action: primaryAction) {
                Text("Activate")
            }
            .buttonStyle(PillButtonStyle())
        case .available:
            Button(action: primaryAction) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down")
                    Text("Download")
                }
            }
            .buttonStyle(PillButtonStyle())
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text(progressPercent(progress))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var meta: String {
        "\(engineLabel) · \(DS.formatBytes(Int(variant.sizeBytes)))"
    }

    private var engineLabel: String {
        switch variant.engineID {
        case .whisperKit: return "WhisperKit"
        case .parakeet:   return "Parakeet"
        default:          return variant.engineID.rawValue.capitalized
        }
    }

    private var chips: [TagChip.Chip] {
        var result: [TagChip.Chip] = []
        if variant.qualityTier == .best {
            result.append(.init(label: "High accuracy", color: .orange))
        }
        if variant.speedTier == .fastest {
            result.append(.init(label: "Fast", color: .green))
        }
        if case .some(.only(let codes)) = variant.languageScope, codes == ["en"] {
            result.append(.init(label: "English-only", color: .blue))
        }
        return result
    }

    private var iconName: String {
        switch variant.engineID {
        case .parakeet: return "bird"
        case .whisperKit: return "waveform"
        default: return "cpu"
        }
    }

    private var iconTint: Color {
        switch variant.engineID {
        case .parakeet: return .green
        case .whisperKit: return DS.Color.accent
        default: return .secondary
        }
    }

    private var borderColor: Color {
        if case .active = kind { return DS.Color.accent.opacity(0.55) }
        return DS.Color.separator.opacity(0.6)
    }

    private var borderWidth: CGFloat {
        if case .active = kind { return 1.5 }
        return 0.5
    }

    private func progressPercent(_ value: Double) -> String {
        let clamped = max(0, min(1, value))
        return "\(Int(clamped * 100))%"
    }
}

// MARK: - Tag chip

private struct TagChip: View {
    struct Chip: Identifiable {
        let label: String
        let color: Color
        var id: String { label }
    }

    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(DS.Color.accent.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .contentShape(Capsule())
    }
}

// MARK: - Categories

private struct ModelsCategory: Identifiable {
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
            symbol: "applelogo",
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

private struct CategoryRow: View {
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

// MARK: - Preview

#Preview("Models pane") {
    ModelsSettingsPane()
        .environmentObject(AppModel())
        .frame(width: 580, height: 720)
}
