import SwiftUI
import ParolaCore

struct ModelPickerView: View {
    @EnvironmentObject var model: AppModel

    private let groups: [(ModelCategory, [ModelVariant])] = ModelCatalog.groupedForPicker()

    var body: some View {
        Menu {
            ForEach(groups, id: \.0) { category, variants in
                Section(category.displayName) {
                    ForEach(variants, id: \.id) { variant in
                        Button {
                            select(variant: variant)
                        } label: {
                            row(for: variant)
                        }
                    }
                }
            }
            Divider()
            Button("Refresh") { model.refreshModelList() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(currentLabel)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Active model. Models are downloaded on demand.")
    }

    private func row(for variant: ModelVariant) -> some View {
        let installed = model.availableModels.first(where: { $0.name == variant.id })?.isInstalled ?? false
        return HStack {
            if installed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            }
            Text(variant.displayName)
            Spacer()
            Text(DS.formatBytes(Int(variant.sizeBytes)))
                .foregroundStyle(.secondary).font(.caption)
        }
    }

    private func select(variant: ModelVariant) {
        let installed = model.availableModels.first(where: { $0.name == variant.id })?.isInstalled ?? false
        if !installed {
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
