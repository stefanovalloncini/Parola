import SwiftUI
import ParolaCore

/// The default model as a native pop-up: the installed models, grouped as the catalog groups them.
struct ModelPickerView: View {
    @Environment(AppModel.self) private var model
    let leaf: String

    var body: some View {
        let groups = installedGroups
        Picker("Default model", selection: selection) {
            ForEach(groups, id: \.0) { category, variants in
                Section(category.displayName) {
                    ForEach(variants, id: \.id) { variant in
                        Text(verbatim: variant.displayName).tag(variant.id)
                    }
                }
            }
            if !groups.contains(where: { $0.1.contains { $0.id == model.selectedModel } }) {
                Text(verbatim: currentLabel).tag(model.selectedModel)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("Default model. Installed models only.")
        .task { model.refreshModelList() }
        .axLeaf(leaf)
    }

    private var selection: Binding<String> {
        Binding(get: { model.selectedModel }, set: { model.activateModel($0) })
    }

    private var installedGroups: [(ModelCategory, [ModelVariant])] {
        let installed = Set(model.availableModels.filter(\.isInstalled).map(\.name))
        return ModelCatalog.groupedForPicker(isInstalled: { installed.contains($0) }).compactMap { category, variants in
            let kept = variants.filter { installed.contains($0.id) }
            return kept.isEmpty ? nil : (category, kept)
        }
    }

    private var currentLabel: String {
        if let variant = ModelCatalog.variant(id: model.selectedModel) {
            return variant.displayName
        }
        let installed = model.availableModels.first(where: { $0.name == model.selectedModel })?.label
        return Self.capped(installed ?? model.selectedModel)
    }

    static func shortLabel(for displayName: String) -> String {
        let replacements: [String: String] = [
            "Whisper Large v3 Turbo": "Whisper Turbo",
            "Whisper Large v3": "Whisper Large",
            "Whisper Tiny (English)": "Whisper Tiny EN",
            "Parakeet TDT 0.6B v2": "Parakeet v2",
            "Parakeet TDT 0.6B v3": "Parakeet v3",
            "Distil Whisper Large v3": "Distil Large",
        ]
        return capped(replacements[displayName] ?? displayName)
    }

    /// The catalog's own names all fit; an uncurated model id would push the intake strip's other controls aside.
    static let labelCharacterCap = 24

    static func capped(_ label: String) -> String {
        label.count <= labelCharacterCap ? label : String(label.prefix(labelCharacterCap - 1)) + "…"
    }
}

/// A picker that offers downloads lists the whole catalog; one that does not (Settings) only lists what is installed.
struct ModelPickerPopover: View {
    @Environment(AppModel.self) private var model
    @Binding var searchText: String
    @Binding var installedOnly: Bool
    let offersDownloads: Bool

    private var groups: [(ModelCategory, [ModelVariant])] {
        let installed = Set(model.availableModels.filter(\.isInstalled).map(\.name))
        return ModelCatalog.groupedForPicker(isInstalled: { installed.contains($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .onAppear {
                    model.refreshModelList()
                    model.prewarmSelectedModel()
                }
                .padding(.horizontal, DS.Spacing.small)
                .padding(.top, DS.Spacing.tight)
                .padding(.bottom, DS.Spacing.snug)

            if offersDownloads {
                installedOnlyToggle
                    .padding(.horizontal, DS.Spacing.regular)
                    .padding(.bottom, DS.Spacing.tight)
            }

            PillPopoverList {
                let filtered = filteredGroups
                if filtered.isEmpty {
                    Text("No models match")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .padding(.horizontal, DS.Spacing.regular)
                        .padding(.vertical, DS.Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if let pinned = pinnedVariant {
                        PillPopoverSectionHeader(title: String(localized: "Pinned"))
                        row(for: pinned)
                            .contextMenu {
                                Button("Unpin") { model.pinnedModel = "" }
                            }
                    }
                    ForEach(filtered, id: \.0) { category, variants in
                        PillPopoverSectionHeader(title: category.displayName)
                        ForEach(variants, id: \.id) { variant in
                            row(for: variant)
                                .contextMenu {
                                    if model.pinnedModel == variant.id {
                                        Button("Unpin") { model.pinnedModel = "" }
                                    } else {
                                        Button("Pin to Top") { model.pinnedModel = variant.id }
                                    }
                                }
                        }
                    }
                }
            }

            Divider().padding(.vertical, DS.Spacing.tight)
            PillPopoverRow(
                title: String(localized: "Manage models…"),
                leading: .symbol("slider.horizontal.3"),
                action: { model.openSettings(route: .localModels) }
            )
        }
        .padding(.horizontal, DS.Spacing.snug)
    }

    private func row(for variant: ModelVariant) -> some View {
        PillPopoverRow(
            title: variant.displayName,
            subtitle: variant.tagline,
            badge: Self.scopeBadge(for: variant),
            isSelected: variant.id == model.selectedModel,
            leading: .tile(ModelEngineIcon.symbol(for: variant.engineID), tint: ModelEngineIcon.tint(for: variant.engineID)),
            trailing: Self.trailing(for: variant, isInstalled: isInstalled(variant), phase: model.phase),
            dismissesOnSelect: isInstalled(variant),
            action: { select(variant: variant) }
        )
    }

    /// Built-in engines report no download size; "Zero kB" reads like a bug next to real sizes.
    static func sizeLabel(_ variant: ModelVariant) -> String {
        variant.sizeBytes > 0 ? AppFormat.byteSize(variant.sizeBytes) : String(localized: "Built in")
    }

    /// A restricted language scope narrows the language picker, and the badge says so before the pick.
    static func scopeBadge(for variant: ModelVariant) -> String? {
        guard case .some(.only(let codes)) = variant.languageScope else { return nil }
        if codes == ["en"] { return String(localized: "English only") }
        return String(localized: "\(codes.count) languages")
    }

    static func trailing(for variant: ModelVariant, isInstalled: Bool, phase: AppModel.Phase) -> PillPopoverRow.Trailing {
        if case .downloadingModel(let name, let progress) = phase, name == variant.id {
            return .progress(progress)
        }
        return isInstalled ? .text(sizeLabel(variant)) : .download(sizeLabel(variant))
    }

    private var searchField: some View {
        SearchPill(text: $searchText, placeholder: "Search models", leaf: "ModelPicker.TextField.Search")
    }

    private var installedOnlyToggle: some View {
        Toggle(isOn: $installedOnly) {
            Text("Installed only")
                .font(DS.Font.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .frame(maxWidth: .infinity, alignment: .leading)
        .axLeaf("ModelPicker.Toggle.InstalledOnly")
    }

    private var filteredGroups: [(ModelCategory, [ModelVariant])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return groups.compactMap { category, variants in
            let matches = variants.filter { variant in
                if (installedOnly || !offersDownloads) && !isInstalled(variant) { return false }
                if query.isEmpty { return true }
                return variant.displayName.lowercased().contains(query)
            }
            return matches.isEmpty ? nil : (category, matches)
        }
    }

    private var pinnedVariant: ModelVariant? {
        guard !model.pinnedModel.isEmpty else { return nil }
        return ModelCatalog.variant(id: model.pinnedModel)
    }

    private func isInstalled(_ variant: ModelVariant) -> Bool {
        model.availableModels.first(where: { $0.name == variant.id })?.isInstalled ?? false
    }

    private func select(variant: ModelVariant) {
        // Activate first: a refused or already-failing download corrects the selection
        // synchronously against what was just picked, not against whatever came before it.
        model.activateModel(variant.id)
        if !isInstalled(variant) {
            model.downloadModel(variant.id)
        }
    }
}
