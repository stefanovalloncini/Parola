import SwiftUI
import ParolaCore

struct ModelsSettingsPane: View {
    @Environment(AppModel.self) private var model

    @State private var searchText = ""
    @State private var installFilter: InstallFilter = .all
    @State private var sortOption: SortOption = .recommended
    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion: Identifiable {
        let id: String
        let displayName: String
        let sizeBytes: Int64?
    }

    enum InstallFilter: String, CaseIterable, Identifiable {
        case all, installed, available
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .installed: return "Installed"
            case .available: return "Available"
            }
        }
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case recommended, smallest, largest, nameAscending, nameDescending
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recommended: return "Recommended"
            case .smallest: return "Smallest first"
            case .largest: return "Largest first"
            case .nameAscending: return "Name A→Z"
            case .nameDescending: return "Name Z→A"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StorageRow()
                modelsUsageRow
                libraryUsageRow
                controls
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Color.surface)
        .task { model.refreshModelList() }
        .confirmationDialog(
            confirmationTitle,
            isPresented: isConfirmingDelete,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { item in
            Button("Delete from disk", role: .destructive) {
                model.deleteModel(item.id)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { item in
            if let bytes = item.sizeBytes {
                Text("This will remove \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) from disk. You can re-download it later.")
            } else {
                Text("This will remove the model from disk. You can re-download it later.")
            }
        }
    }

    private var confirmationTitle: String {
        guard let item = pendingDeletion else { return "Delete model?" }
        return "Delete \(item.displayName)?"
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var modelsUsageRow: some View {
        let totalBytes = model.modelSizes.values.reduce(Int64(0), +)
        let installedCount = model.availableModels.filter(\.isInstalled).count
        return UsageRow(
            icon: "cpu",
            label: "Models on disk:",
            value: "\(installedCount) installed · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
        )
    }

    private var libraryUsageRow: some View {
        let totalBytes = model.libraryBundleSizes.values.reduce(Int64(0), +)
        return UsageRow(
            icon: "tray.full",
            label: "Library:",
            value: "\(model.libraryEntries.count) entries · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
        )
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SearchPill(text: $searchText, placeholder: "Search models…")
                sortMenu
            }
            chipsRow
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: \(sortOption.label)")
        .axLeaf("ModelsSettings.Menu.Sort")
    }

    private var chipsRow: some View {
        HStack(spacing: 6) {
            ForEach(InstallFilter.allCases) { filter in
                Chip(
                    title: LocalizedStringKey(filter.label),
                    isSelected: installFilter == filter,
                    size: .regular,
                    weight: .semibold
                ) {
                    installFilter = filter
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let installed = filteredInstalledVariants
        let recommended = filteredRecommendedVariants
        let categories = installFilter == .all ? filteredCategories : []

        if installed.isEmpty && recommended.isEmpty && categories.isEmpty && orphans.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 28) {
                if !installed.isEmpty || installFilter == .installed {
                    downloadedSection(installed)
                }
                if !orphans.isEmpty {
                    orphansSection(orphans)
                }
                if !recommended.isEmpty || installFilter == .available {
                    recommendedSection(recommended)
                }
                if !categories.isEmpty {
                    categoriesSection(categories)
                }
            }
        }
    }

    private var orphans: [ModelInfo] {
        guard installFilter != .available else { return [] }
        let catalogIDs = Set(ModelCatalog.all.map(\.id))
        let needle = searchNeedle
        return model.availableModels.filter { info in
            guard info.isInstalled, !catalogIDs.contains(info.name) else { return false }
            guard let needle else { return true }
            return info.name.lowercased().contains(needle)
        }
    }

    private func orphansSection(_ entries: [ModelInfo]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Other Files on Disk", count: entries.count)
            Text("These directories aren't in the current model catalog — usually leftovers from older app versions. Safe to delete.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVStack(spacing: 8) {
                ForEach(entries) { entry in
                    let displaySize = model.modelSizes[entry.name]
                        ?? entry.approximateSizeBytes.map { Int64($0) }
                    OrphansRow(
                        entry: entry,
                        displaySize: displaySize,
                        isDeleting: model.modelsBeingDeleted.contains(entry.name)
                    ) {
                        pendingDeletion = PendingDeletion(
                            id: entry.name,
                            displayName: entry.name,
                            sizeBytes: displaySize
                        )
                    }
                }
            }
        }
    }

    // MARK: - Downloaded

    private func downloadedSection(_ variants: [ModelVariant]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Downloaded", count: variants.count)
            if variants.isEmpty {
                DownloadedEmpty()
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(variants) { variant in
                        let isActive = model.selectedModel == variant.id
                        DownloadedRow(
                            variant: variant,
                            isActive: isActive,
                            actualSizeBytes: model.modelSizes[variant.id],
                            isDeleting: model.modelsBeingDeleted.contains(variant.id),
                            onActivate: { model.selectedModel = variant.id },
                            onRequestDelete: isActive ? nil : {
                                pendingDeletion = PendingDeletion(
                                    id: variant.id,
                                    displayName: variant.displayName,
                                    sizeBytes: model.modelSizes[variant.id] ?? Int64(variant.sizeBytes)
                                )
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Recommended

    private func recommendedSection(_ variants: [ModelVariant]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Recommended Models", count: variants.count)
            LazyVStack(spacing: 10) {
                ForEach(variants) { variant in
                    RecommendedRow(
                        variant: variant,
                        kind: downloadKind(for: variant)
                    ) {
                        model.downloadModel(variant.id)
                    }
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

    private func categoriesSection(_ categories: [ModelsCategory]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Categories", count: nil)
            ModelCategorySection(categories: categories)
        }
    }

    // MARK: - Data

    private var installedIDs: Set<String> {
        Set(model.availableModels.filter(\.isInstalled).map(\.name))
    }

    private var filteredInstalledVariants: [ModelVariant] {
        guard installFilter != .available else { return [] }
        let base = ModelCatalog.all.filter { installedIDs.contains($0.id) }
        return sorted(matching(base))
    }

    private var filteredRecommendedVariants: [ModelVariant] {
        guard installFilter != .installed else { return [] }
        let base = ModelCatalog.all.filter { !installedIDs.contains($0.id) }
        return sorted(matching(base))
    }

    private var filteredCategories: [ModelsCategory] {
        guard let needle = searchNeedle else { return ModelsCategory.all }
        return ModelsCategory.all.filter {
            $0.title.lowercased().contains(needle)
                || $0.description.lowercased().contains(needle)
        }
    }

    private func matching(_ variants: [ModelVariant]) -> [ModelVariant] {
        guard let needle = searchNeedle else { return variants }
        return variants.filter { $0.displayName.lowercased().contains(needle) }
    }

    private var searchNeedle: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private func sorted(_ variants: [ModelVariant]) -> [ModelVariant] {
        switch sortOption {
        case .recommended:
            return variants
        case .smallest:
            return variants.sorted { $0.sizeBytes < $1.sizeBytes }
        case .largest:
            return variants.sorted { $0.sizeBytes > $1.sizeBytes }
        case .nameAscending:
            return variants.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .nameDescending:
            return variants.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedDescending }
        }
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
        .environment(AppModel())
        .frame(width: 580, height: 720)
}
