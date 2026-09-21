import AppKit
import SwiftUI
import ParolaCore

struct EngineScene: View {
    @Environment(AppModel.self) private var model

    /// Apple Speech is `.recommended` too — for its own engine — so the chip follows the rule that picked the Whisper card.
    static func isRecommended(_ variant: ModelVariant) -> Bool {
        variant.category == .recommended && variant.engineID != .appleSpeech
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("Choose how it listens.")
                .font(DS.Font.hero)
                .foregroundStyle(DS.Color.primaryText)
                .sceneEntrance(order: 0)
            Text("You can change this any time in Settings.")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.secondaryText)
                .sceneEntrance(order: 1)
            HStack(alignment: .top, spacing: DS.Spacing.medium) {
                ForEach(choices) { variant in
                    EngineCard(
                        variant: variant,
                        isSelected: model.introduction.ringedEngineID(current: model.selectedModel) == variant.id,
                        isRecommended: Self.isRecommended(variant),
                        isInstalled: model.isModelInstalled(variant.id),
                        downloadProgress: downloadProgress(for: variant.id),
                        choose: { model.introduction.chooseEngine(variant.id) }
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DS.Spacing.small)
            .sceneEntrance(order: 2)
            moreModelsLink
                .sceneEntrance(order: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var choices: [ModelVariant] {
        model.introduction.engineChoices.compactMap { ModelCatalog.variant(id: $0) }
    }

    private var moreModelsLink: some View {
        // A SettingsLink can't carry an action, and the pane has to be set before the window opens.
        Button {
            model.settingsPane = SettingsRoute.localModels.rawValue
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } label: {
            Text("More models in Settings")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.accentText)
        }
        .buttonStyle(.plain)
        .axLeaf("Introduction.Button.MoreModels")
    }

    private func downloadProgress(for id: String) -> Double? {
        guard case .downloadingModel(let name, let progress) = model.phase, name == id else { return nil }
        return progress
    }
}

private struct EngineCard: View {
    let variant: ModelVariant
    let isSelected: Bool
    let isRecommended: Bool
    let isInstalled: Bool
    let downloadProgress: Double?
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                header
                Text(title)
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(DS.Spacing.medium)
            .background {
                shape.fill(DS.Color.surfaceElevated)
                shape.fill(isSelected ? DS.Color.accent.opacity(0.10) : .clear)
            }
            .overlay(
                shape.strokeBorder(
                    isSelected ? DS.Color.accent : DS.Color.separator,
                    lineWidth: isSelected ? 2 : 0.5
                )
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable()
        .onKeyPress(.space) {
            choose()
            return .handled
        }
        .animation(DS.Motion.rowState, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .axLeaf("Introduction.Button.Engine.\(variant.id)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.small) {
            ModelEngineIcon(engineID: variant.engineID)
            Spacer(minLength: DS.Spacing.small)
            if isRecommended {
                Text("Recommended").accentPill(font: DS.Font.caption)
            }
        }
    }

    /// The catalog's "(system)" earns its place next to nine Whispers, not next to one.
    private var title: LocalizedStringKey {
        variant.engineID == .appleSpeech ? "Apple Speech" : LocalizedStringKey(variant.displayName)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
    }

    @ViewBuilder
    private var detail: some View {
        if let downloadProgress {
            HStack(spacing: DS.Spacing.small) {
                DSProgressBar(value: downloadProgress)
                Text(AppFormat.percent(downloadProgress))
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        } else {
            Text(line)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var line: LocalizedStringKey {
        if variant.engineID == .appleSpeech { return "Built into macOS. Ready now." }
        if isInstalled { return "More accurate. Installed." }
        return "More accurate. Downloads \(AppFormat.byteSize(variant.sizeBytes)) once."
    }
}
