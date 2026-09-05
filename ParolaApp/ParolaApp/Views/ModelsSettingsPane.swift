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
        VStack(alignment: .leading, spacing: 16) {
            if let error = model.modelActionError {
                modelErrorBanner(error)
            }
            StorageRow()
            modelsUsageRow
            libraryUsageRow
            controls
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("This will remove \(AppFormat.byteSize(bytes)) from disk. You can re-download it later.")
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
        let summary = model.modelsOnDiskSummary
        return UsageRow(
            icon: "cpu",
            label: "Models on disk:",
            value: "\(summary.count) installed · \(AppFormat.byteSize(summary.bytes))"
        )
    }

    private var libraryUsageRow: some View {
        let totalBytes = model.libraryBundleSizes.values.reduce(Int64(0), +)
        return UsageRow(
            icon: "tray.full",
            label: "Library:",
            value: "\(model.libraryEntries.count) entries · \(AppFormat.byteSize(totalBytes))"
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
                .font(DS.Font.calloutEmphasized)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .fill(DS.Palette.subtleFill)
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
        let sections = self.sections

        if sections.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 28) {
                if !sections.installed.isEmpty || installFilter == .installed {
                    downloadedSection(sections.installed)
                }
                if !sections.orphans.isEmpty {
                    orphansSection(sections.orphans)
                }
                if !sections.recommended.isEmpty || installFilter == .available {
                    recommendedSection(sections.recommended)
                }
                if !sections.categories.isEmpty {
                    categoriesSection(sections.categories)
                }
            }
        }
    }

    private func orphansSection(_ entries: [ModelInfo]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Other files on disk", count: entries.count)
            Text("These directories aren't in the current model catalog — usually leftovers from older app versions. Safe to delete.")
                .font(DS.Font.caption)
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
                            onActivate: { model.activateModel(variant.id) },
                            onRequestDelete: (isActive || variant.engineID == .appleSpeech) ? nil : {
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
            sectionHeader("Recommended models", count: variants.count)
            LazyVStack(spacing: 10) {
                ForEach(variants) { variant in
                    LiveRecommendedRow(variant: variant)
                }
            }
        }
    }

    private func modelErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.warning)
            Text(message)
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { model.modelActionError = nil }
                .controlSize(.small)
                .axLeaf("Models.Button.DismissError")
        }
        .padding(10)
        .background(DS.Palette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
    }

    // MARK: - Categories

    private func categoriesSection(_ categories: [ModelsCategory]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Engine families", count: nil)
            ModelCategorySection(categories: categories)
        }
    }

    // MARK: - Data

    private struct Sections {
        var installed: [ModelVariant] = []
        var recommended: [ModelVariant] = []
        var categories: [ModelsCategory] = []
        var orphans: [ModelInfo] = []

        var isEmpty: Bool {
            installed.isEmpty && recommended.isEmpty && categories.isEmpty && orphans.isEmpty
        }
    }

    /// Every list the pane renders, from one pass over the model list. Kept together so a redraw
    /// doesn't rebuild the installed-id set and re-sort the catalog once per section.
    private var sections: Sections {
        let installedIDs = Set(model.availableModels.filter(\.isInstalled).map(\.name))
        let allowed = ManagedConfiguration.shared.filterAllowed(ModelCatalog.all)
        var sections = Sections()

        if installFilter != .available {
            sections.installed = sorted(matching(allowed.filter { installedIDs.contains($0.id) }))
            let catalogIDs = Set(ModelCatalog.all.map(\.id))
            let needle = searchNeedle
            sections.orphans = model.availableModels.filter { info in
                guard info.isInstalled, !catalogIDs.contains(info.name) else { return false }
                guard let needle else { return true }
                return info.name.lowercased().contains(needle)
            }
        }
        if installFilter != .installed {
            sections.recommended = sorted(matching(allowed.filter { !installedIDs.contains($0.id) }))
        }
        if installFilter == .all {
            sections.categories = filteredCategories
        }
        return sections
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

    private func sectionHeader(_ title: LocalizedStringKey, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(DS.Font.title3)
            if let count, count > 0 {
                Text("\(count)")
                    .font(DS.Font.calloutMedium)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// Owns the pane's only read of `phase`, which a download rewrites at every percent. Reading it
/// from the pane body instead would re-derive every section list a hundred times per download.
private struct LiveRecommendedRow: View {
    @Environment(AppModel.self) private var model
    let variant: ModelVariant

    var body: some View {
        RecommendedRow(
            variant: variant,
            kind: kind,
            downloadDisabled: downloadInFlight,
            onDownload: { model.downloadModel(variant.id) },
            onCancelDownload: { model.cancelModelDownload() }
        )
    }

    private var kind: ModelCardRow.Kind {
        if case .downloadingModel(let name, let progress) = model.phase, name == variant.id {
            return .downloading(progress: progress)
        }
        return .available
    }

    private var downloadInFlight: Bool {
        if case .downloadingModel = model.phase { return true }
        return model.downloadBlockedReason != nil
    }
}

#Preview("Models pane") {
    ModelsSettingsPane()
        .environment(AppModel())
        .frame(width: 580, height: 720)
}
