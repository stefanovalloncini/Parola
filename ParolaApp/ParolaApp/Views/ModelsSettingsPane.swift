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
                        ModelCardRow(
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
                    ModelCardRow(
                        variant: variant,
                        kind: downloadKind(for: variant),
                        primaryAction: { model.downloadModel(variant.id) }
                    )
                }
            }
        }
    }

    private func downloadKind(for variant: ModelVariant) -> ModelCardRow.Kind {
        if case .downloadingModel(let name, let progress) = model.phase, name == variant.id {
            return .downloading(progress: progress)
        }
        return .available
    }

    // MARK: - Categories

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Categories", count: nil)
            ModelCategorySection(categories: ModelsCategory.all)
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

#Preview("Models pane") {
    ModelsSettingsPane()
        .environmentObject(AppModel())
        .frame(width: 580, height: 720)
}
