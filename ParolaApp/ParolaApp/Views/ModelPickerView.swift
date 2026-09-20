import SwiftUI
import ParolaCore

struct ModelPickerView: View {
    @Environment(AppModel.self) private var model

    @State private var searchText = ""
    @State private var installedOnly = false

    /// Frozen at first use: ModelStore re-applies the managed allowlist on every scan, so a stale row here cannot reach a blocked model.
    private static let groups: [(ModelCategory, [ModelVariant])] = ModelCatalog.groupedForPicker()

    var body: some View {
        PillPickerButton(icon: "cpu", caption: "Model", value: currentLabel) {
            VStack(spacing: 0) {
                searchField
                    .onAppear { model.prewarmSelectedModel() }
                    .padding(.horizontal, DS.Spacing.small)
                    .padding(.top, DS.Spacing.tight)
                    .padding(.bottom, DS.Spacing.snug)

                installedOnlyToggle
                    .padding(.horizontal, DS.Spacing.regular)
                    .padding(.bottom, DS.Spacing.tight)

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
                        PillPopoverSectionHeader(title: "Pinned")
                        let installed = isInstalled(pinned)
                        PillPopoverRow(
                            title: pinned.displayName,
                            isSelected: pinned.id == model.selectedModel,
                            trailingText: Self.sizeLabel(pinned),
                            badgeText: Self.badge(for: pinned),
                            help: pinned.tagline,
                            leadingSystemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle",
                            leadingTint: installed ? DS.Palette.success : .secondary,
                            action: { select(variant: pinned) }
                        )
                        .contextMenu {
                            Button("Unpin") { model.pinnedModel = "" }
                        }
                    }
                    ForEach(filtered, id: \.0) { category, variants in
                        PillPopoverSectionHeader(title: category.displayName)
                        ForEach(variants, id: \.id) { variant in
                            let installed = isInstalled(variant)
                            PillPopoverRow(
                                title: variant.displayName,
                                isSelected: variant.id == model.selectedModel,
                                trailingText: Self.sizeLabel(variant),
                                badgeText: Self.badge(for: variant),
                                help: variant.tagline,
                                leadingSystemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle",
                                leadingTint: installed ? DS.Palette.success : .secondary,
                                action: { select(variant: variant) }
                            )
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

                Divider().padding(.vertical, DS.Spacing.tight)
                PillPopoverRow(
                    title: "Refresh",
                    leadingSystemImage: "arrow.clockwise",
                    action: { model.refreshModelList() }
                )
            }
            .padding(.horizontal, DS.Spacing.snug)
        }
        .help("Active model. Models are downloaded on demand.")
    }

    /// Built-in engines report no download size; "Zero kB" reads like a bug next to real sizes.
    static func sizeLabel(_ variant: ModelVariant) -> String {
        variant.sizeBytes > 0 ? AppFormat.byteSize(variant.sizeBytes) : String(localized: "Built in")
    }

    /// English-only models silently disable the language picker, so say so before the pick.
    static func badge(for variant: ModelVariant) -> String? {
        guard case .some(.only(let codes)) = variant.languageScope, codes == ["en"] else { return nil }
        return String(localized: "EN only")
    }

    private var searchField: some View {
        SearchPill(
            text: $searchText,
            placeholder: "Search models",
            identifier: "ModelPicker.TextField.Search",
            clearButtonIdentifier: "ModelPicker.Button.ClearSearch"
        )
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
        return Self.groups.compactMap { category, variants in
            let matches = variants.filter { variant in
                if installedOnly && !isInstalled(variant) { return false }
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

    private var currentLabel: String {
        if let variant = ModelCatalog.variant(id: model.selectedModel) {
            return Self.shortLabel(for: variant.displayName)
        }
        return model.availableModels.first(where: { $0.name == model.selectedModel })?.label ?? model.selectedModel
    }

    static func shortLabel(for displayName: String) -> String {
        let replacements: [String: String] = [
            "Whisper Large v3 Turbo": "Whisper Turbo",
            "Whisper Large v3": "Whisper Large",
            "Whisper Tiny (English)": "Whisper Tiny EN",
            "Parakeet TDT 0.6B v2": "Parakeet v2",
            "Distil Whisper Large v3": "Distil Large",
        ]
        return replacements[displayName] ?? displayName
    }
}
