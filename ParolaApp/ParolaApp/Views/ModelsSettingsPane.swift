import SwiftUI
import ParolaCore

struct ModelsSettingsPane: View {
    @EnvironmentObject var model: AppModel

    @State private var searchText = ""
    @State private var installFilter: InstallFilter = .all
    @State private var sortOption: SortOption = .recommended

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
                controls
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Color.surface)
        .task { model.refreshModelList() }
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
    }

    private var chipsRow: some View {
        HStack(spacing: 6) {
            ForEach(InstallFilter.allCases) { filter in
                FilterChip(
                    label: filter.label,
                    isOn: installFilter == filter
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

        if installed.isEmpty && recommended.isEmpty && categories.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 28) {
                if !installed.isEmpty || installFilter == .installed {
                    downloadedSection(installed)
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

    // MARK: - Downloaded

    private func downloadedSection(_ variants: [ModelVariant]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Downloaded", count: variants.count)
            if variants.isEmpty {
                emptyDownloaded
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(variants) { variant in
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

    private func recommendedSection(_ variants: [ModelVariant]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Recommended Models", count: variants.count)
            LazyVStack(spacing: 10) {
                ForEach(variants) { variant in
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

private struct FilterChip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(background)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(DS.Color.separator.opacity(isOn ? 0 : 0.4), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var background: Color {
        if isOn { return DS.Color.accent }
        if hovered { return DS.Color.surfaceElevated }
        return DS.Color.surfaceElevated.opacity(0.6)
    }
}

#Preview("Models pane") {
    ModelsSettingsPane()
        .environmentObject(AppModel())
        .frame(width: 580, height: 720)
}
