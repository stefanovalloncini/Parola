import SwiftUI
import ParolaCore

struct ModelPickerView: View {
    @EnvironmentObject var model: AppModel

    private let groups: [(ModelCategory, [ModelVariant])] = ModelCatalog.groupedForPicker()

    var body: some View {
        PillPickerButton(icon: "cpu", caption: "Model", value: currentLabel) {
            VStack(spacing: 0) {
                ForEach(groups, id: \.0) { category, variants in
                    PillPopoverSectionHeader(title: category.displayName)
                    ForEach(variants, id: \.id) { variant in
                        let installed = isInstalled(variant)
                        PillPopoverRow(
                            title: variant.displayName,
                            isSelected: variant.id == model.selectedModel,
                            trailingText: DS.formatBytes(Int(variant.sizeBytes)),
                            leadingSystemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle",
                            leadingTint: installed ? .green : .secondary,
                            action: { select(variant: variant) }
                        )
                    }
                }
                Divider().padding(.vertical, 4)
                PillPopoverRow(
                    title: "Refresh",
                    leadingSystemImage: "arrow.clockwise",
                    action: { model.refreshModelList() }
                )
            }
            .padding(.horizontal, 6)
        }
        .help("Active model. Models are downloaded on demand.")
    }

    private func isInstalled(_ variant: ModelVariant) -> Bool {
        model.availableModels.first(where: { $0.name == variant.id })?.isInstalled ?? false
    }

    private func select(variant: ModelVariant) {
        if !isInstalled(variant) {
            model.downloadModel(variant.id)
        }
        model.selectedModel = variant.id
        applyDefaultLanguageIfNeeded(for: variant)
    }

    private func applyDefaultLanguageIfNeeded(for variant: ModelVariant) {
        if case .some(.only(let codes)) = variant.languageScope, codes == ["en"] {
            model.selectedLanguage = "en"
        }
    }

    private var currentLabel: String {
        if let variant = ModelCatalog.variant(id: model.selectedModel) {
            return variant.displayName
        }
        return model.availableModels.first(where: { $0.name == model.selectedModel })?.label ?? model.selectedModel
    }
}
