import AppKit
import SwiftUI
import ParolaCore

struct EngineScene: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("Choose how it listens.")
                .font(DS.Font.hero)
                .foregroundStyle(DS.Color.primaryText)
            Text("You can change this any time in Settings.")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.secondaryText)
            HStack(alignment: .top, spacing: DS.Spacing.medium) {
                ForEach(choices) { variant in
                    EngineCard(
                        variant: variant,
                        isSelected: model.introduction.selectedEngineID == variant.id,
                        isInstalled: model.isModelInstalled(variant.id),
                        downloadProgress: downloadProgress(for: variant.id),
                        choose: { model.introduction.chooseEngine(variant.id) }
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DS.Spacing.small)
            moreModelsLink
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
    let isInstalled: Bool
    let downloadProgress: Double?
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                ModelEngineIcon(engineID: variant.engineID)
                Text(variant.displayName)
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(DS.Spacing.medium)
            .background(DS.Color.surfaceElevated, in: shape)
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
        if isInstalled { return "Most accurate. Installed." }
        return "Most accurate. Downloads \(AppFormat.byteSize(variant.sizeBytes)) once."
    }
}
