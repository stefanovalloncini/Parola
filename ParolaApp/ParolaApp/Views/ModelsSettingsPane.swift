import SwiftUI
import ParolaCore

struct ModelsSettingsPane: View {
    @EnvironmentObject var model: AppModel

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
                storageRow
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
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
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

    private var modelsUsageRow: some View {
        let totalBytes = model.modelSizes.values.reduce(Int64(0), +)
        let installedCount = model.availableModels.filter(\.isInstalled).count
        return HStack(spacing: 8) {
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
            Text("Models on disk:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(installedCount) installed · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var libraryUsageRow: some View {
        let totalBytes = model.libraryBundleSizes.values.reduce(Int64(0), +)
        return HStack(spacing: 8) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
            Text("Library:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(model.libraryEntries.count) entries · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var storageRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text("Storage:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(storageDisplayPath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") { chooseStorage() }
                .controlSize(.small)
            if isCustomStorage {
                Button("Use Default") { resetStorage() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var storageDisplayPath: String {
        let custom = UserDefaults.standard.string(forKey: ModelStore.storageOverrideKey)
        if let custom, !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return (custom as NSString).abbreviatingWithTildeInPath
        }
        return (ModelStore.defaultDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    private var isCustomStorage: Bool {
        UserDefaults.standard.string(forKey: ModelStore.storageOverrideKey)?
            .trimmingCharacters(in: .whitespaces).isEmpty == false
    }

    private func chooseStorage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose models folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: ModelStore.storageOverrideKey)
        showRestartAlert()
    }

    private func resetStorage() {
        UserDefaults.standard.removeObject(forKey: ModelStore.storageOverrideKey)
        showRestartAlert()
    }

    private func showRestartAlert() {
        let alert = NSAlert()
        alert.messageText = "Restart required"
        alert.informativeText = "Quit and relaunch Parola for the new models folder to take effect."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
                    orphanRow(entry)
                }
            }
        }
    }

    private func orphanRow(_ entry: ModelInfo) -> some View {
        let displaySize = model.modelSizes[entry.name]
            ?? entry.approximateSizeBytes.map { Int64($0) }
        let isDeleting = model.modelsBeingDeleted.contains(entry.name)
        return HStack(spacing: 12) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline)
                if let bytes = displaySize {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isDeleting {
                ProgressView().controlSize(.small)
                Text("Deleting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    pendingDeletion = PendingDeletion(
                        id: entry.name,
                        displayName: entry.name,
                        sizeBytes: displaySize
                    )
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete this folder from disk")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DS.Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                            actualSizeBytes: model.modelSizes[variant.id],
                            isDeleting: model.modelsBeingDeleted.contains(variant.id),
                            primaryAction: { model.selectedModel = variant.id },
                            deleteAction: model.selectedModel == variant.id ? nil : {
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
