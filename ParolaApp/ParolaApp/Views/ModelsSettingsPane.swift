import SwiftUI
import ParolaCore

struct ModelsSettingsPane: View {
    @Environment(AppModel.self) private var model

    @State private var searchText = ""
    @State private var installFilter: InstallFilter = .all
    @State private var sortOption: SortOption = .recommended
    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion: Identifiable {
        enum Kind { case model, modelAndEarlierDownload, earlierDownload }

        let id: String
        let displayName: String
        let sizeBytes: Int64?
        var kind: Kind = .model
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
        SettingsForm {
            usageCard
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
            Button("Delete from Disk", role: .destructive) {
                switch item.kind {
                case .model, .modelAndEarlierDownload: model.deleteModel(item.id)
                case .earlierDownload: model.reclaimSupersededCopy(item.id)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { item in
            Text(verbatim: confirmationMessage(for: item))
        }
    }

    private func confirmationMessage(for item: PendingDeletion) -> String {
        let size = AppFormat.byteSize(item.sizeBytes ?? 0)
        switch item.kind {
        case .model:
            guard item.sizeBytes != nil else {
                return String(localized: "This will remove the model from disk. You can re-download it later.")
            }
            return String(localized: "This will remove \(size) from disk. You can re-download it later.")
        case .modelAndEarlierDownload:
            return withSharedFolderNote(String(
                localized: "This will remove \(size) from disk, including an earlier download. You can re-download the model later."
            ))
        case .earlierDownload:
            return withSharedFolderNote(String(localized: "This will remove \(size) from disk. Parola doesn't use this copy."))
        }
    }

    private func withSharedFolderNote(_ message: String) -> String {
        guard model.modelStoreIsRelocated else { return message }
        return message + String(localized: " Another app that uses this folder may still need it.")
    }

    private var confirmationTitle: String {
        guard let item = pendingDeletion else { return "Delete model?" }
        if item.kind == .earlierDownload {
            return String(localized: "Delete the earlier download of \(item.displayName)?")
        }
        return "Delete \(item.displayName)?"
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var usageCard: some View {
        Section {
            StorageRow()
            modelsUsageRow
            libraryUsageRow
        } header: {
            Text("Storage")
        } footer: {
            if let error = model.modelActionError {
                modelError(error)
            }
        }
    }

    @ViewBuilder
    private var modelsUsageRow: some View {
        let summary = model.modelsOnDiskSummary
        if summary.bytes > 0 {
            UsageRow(icon: "cpu", label: "Models:", value: summary.usageText)
        }
    }

    @ViewBuilder
    private var libraryUsageRow: some View {
        let totalBytes = model.libraryBundleSizes.values.reduce(Int64(0), +)
        if !model.libraryEntries.isEmpty {
            UsageRow(
                icon: "tray.full",
                label: "Library:",
                value: AppModel.libraryUsageText(entries: model.libraryEntries.count, bytes: totalBytes)
            )
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            SearchPill(text: $searchText, placeholder: "Search models…", leaf: "Models.TextField.Search")
            Picker("Show", selection: $installFilter) {
                ForEach(InstallFilter.allCases) { filter in
                    Text(LocalizedStringKey(filter.label)).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .axLeaf("Models.Picker.Filter")
            sortMenu
        }
    }

    /// Not private: a direct accessibility test hosts it alone, since the pane's own `.task` scan keeps it out of the blanket walk.
    var sortMenu: some View {
        RuleListSortMenu(title: "Sort: \(sortOption.label)", leaf: "ModelsSettings.Menu.Sort") {
            sortPicker
        }
    }

    private var sortPicker: some View {
        Picker("Sort by", selection: $sortOption) {
            ForEach(SortOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.inline)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let sections = self.sections
        let shown = sections.isEmpty ? [] : sections.lists(installFilter: installFilter)

        // Always the same section, so the search field keeps the keyboard when a query changes the first list.
        Section {
            if let first = shown.first {
                rows(first, in: sections)
            } else {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity)
            }
        } header: {
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                controls
                if let first = shown.first {
                    sectionHeader(first, in: sections)
                }
            }
        } footer: {
            if let first = shown.first {
                sectionFooter(first)
            }
        }
        ForEach(shown.dropFirst(), id: \.self) { list in
            Section {
                rows(list, in: sections)
            } header: {
                sectionHeader(list, in: sections)
            } footer: {
                sectionFooter(list)
            }
        }
    }

    @ViewBuilder
    private func rows(_ list: Sections.List, in sections: Sections) -> some View {
        switch list {
        case .installed: downloadedRows(sections.installed)
        case .earlier: earlierDownloadRows(sections.earlier)
        case .orphans: orphanRows(sections.orphans)
        case .recommended:
            ForEach(sections.recommended) { variant in
                LiveRecommendedRow(variant: variant)
            }
        case .categories:
            ForEach(sections.categories) { category in
                ModelCategoryRow(category: category)
            }
        }
    }

    @ViewBuilder
    private func sectionFooter(_ list: Sections.List) -> some View {
        switch list {
        case .earlier:
            Text("Newer versions of these models replaced them, and Parola no longer uses them.")
                .foregroundStyle(.secondary)
        case .orphans:
            Text("These directories aren't in the current model catalog — usually leftovers from older app versions. Safe to delete.")
                .foregroundStyle(.secondary)
        case .installed, .recommended, .categories:
            EmptyView()
        }
    }

    private func earlierDownloadRows(_ copies: [SupersededCopy]) -> some View {
        ForEach(copies) { copy in
            EarlierDownloadRow(copy: copy, isDeleting: model.isReclaiming(copy)) {
                pendingDeletion = PendingDeletion(
                    id: copy.variantID,
                    displayName: copy.displayName,
                    sizeBytes: copy.bytes,
                    kind: .earlierDownload
                )
            }
        }
    }

    private func orphanRows(_ entries: [ModelInfo]) -> some View {
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

    @ViewBuilder
    private func downloadedRows(_ variants: [ModelVariant]) -> some View {
        if variants.isEmpty {
            DownloadedEmpty()
        } else {
            ForEach(variants) { variant in
                let isActive = model.selectedModel == variant.id
                DownloadedRow(
                    variant: variant,
                    isActive: isActive,
                    actualSizeBytes: model.modelSizes[variant.id],
                    isDeleting: model.isDeletingModel(variant.id),
                    onActivate: { model.activateModel(variant.id) },
                    onRequestDelete: (isActive || variant.engineID == .appleSpeech) ? nil : {
                        let earlier = model.earlierCopies(of: variant.id)
                        let modelBytes = model.modelSizes[variant.id] ?? Int64(variant.sizeBytes)
                        pendingDeletion = PendingDeletion(
                            id: variant.id,
                            displayName: variant.displayName,
                            sizeBytes: earlier.reduce(modelBytes) { $0 + $1.bytes },
                            kind: earlier.isEmpty ? .model : .modelAndEarlierDownload
                        )
                    }
                )
            }
        }
    }

    private func modelError(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SettingsWarning(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { model.modelActionError = nil }
                .controlSize(.small)
                .axLeaf("Models.Button.DismissError")
        }
    }

    // MARK: - Data

    private struct Sections {
        var installed: [ModelVariant] = []
        var recommended: [ModelVariant] = []
        var categories: [ModelsCategory] = []
        var orphans: [ModelInfo] = []
        var earlier: [SupersededCopy] = []

        enum List {
            case installed, earlier, orphans, recommended, categories

            var title: LocalizedStringKey {
                switch self {
                case .installed: "On This Mac"
                case .earlier: "Earlier downloads"
                case .orphans: "Other files on disk"
                case .recommended: "Recommended models"
                case .categories: "Engine families"
                }
            }
        }

        func count(of list: List) -> Int? {
            switch list {
            case .installed: installed.count
            case .earlier: earlier.count
            case .orphans: orphans.count
            case .recommended: recommended.count
            case .categories: nil
            }
        }

        var isEmpty: Bool {
            installed.isEmpty && recommended.isEmpty && categories.isEmpty && orphans.isEmpty && earlier.isEmpty
        }

        func showsInstalled(installFilter: InstallFilter) -> Bool {
            !installed.isEmpty || installFilter == .installed
        }

        func showsRecommended(installFilter: InstallFilter) -> Bool {
            !recommended.isEmpty || installFilter == .available
        }

        /// The lists to draw, top to bottom; empty when the search leaves none.
        func lists(installFilter: InstallFilter) -> [List] {
            var lists: [List] = []
            if showsInstalled(installFilter: installFilter) { lists.append(.installed) }
            if !earlier.isEmpty { lists.append(.earlier) }
            if !orphans.isEmpty { lists.append(.orphans) }
            if showsRecommended(installFilter: installFilter) { lists.append(.recommended) }
            if !categories.isEmpty { lists.append(.categories) }
            return lists
        }
    }

    /// Every list the pane renders, from one pass over the model list. Kept together so a redraw
    /// doesn't rebuild the installed-id set and re-sort the catalog once per section.
    private var sections: Sections {
        let installedIDs = Set(model.availableModels.filter(\.isInstalled).map(\.name))
        let allowed = ModelCatalog.listedVariants(isInstalled: { installedIDs.contains($0) })
        var sections = Sections()

        if installFilter != .available {
            sections.installed = sorted(matching(allowed.filter { installedIDs.contains($0.id) }))
            let selectableNames = Set(AppModel.selectableModelNames(model.availableModels))
            let needle = searchNeedle
            sections.orphans = model.availableModels.filter { info in
                guard info.isInstalled, !selectableNames.contains(info.name) else { return false }
                guard let needle else { return true }
                return info.name.lowercased().contains(needle)
            }
            sections.earlier = model.supersededCopies.filter { copy in
                guard let needle else { return true }
                return copy.displayName.lowercased().contains(needle)
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

    private func sectionHeader(_ list: Sections.List, in sections: Sections) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(list.title)
            if let count = sections.count(of: list), count > 0 {
                Text(verbatim: AppFormat.integer(count))
                    .monospacedDigit()
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
