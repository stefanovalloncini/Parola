import SwiftUI
import ParolaCore

struct ModelPickerView: View {
    @Environment(AppModel.self) private var model

    @State private var searchText = ""
    @State private var installedOnly = false

    private let groups: [(ModelCategory, [ModelVariant])] = ModelCatalog.groupedForPicker()

    var body: some View {
        PillPickerButton(icon: "cpu", caption: "Model", value: currentLabel) {
            VStack(spacing: 0) {
                searchField
                    .onAppear { model.prewarmSelectedModel() }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 6)

                installedOnlyToggle
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                let filtered = filteredGroups
                if filtered.isEmpty {
                    Text("No models match")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
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
                            leadingTint: installed ? .green : .secondary,
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
                                leadingTint: installed ? .green : .secondary,
                                action: { select(variant: variant) }
                            )
                            .contextMenu {
                                if model.pinnedModel == variant.id {
                                    Button("Unpin") { model.pinnedModel = "" }
                                } else {
                                    Button("Pin to top") { model.pinnedModel = variant.id }
                                }
                            }
                        }
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

    /// Built-in engines report no download size; "Zero kB" reads like a bug next to real sizes.
    static func sizeLabel(_ variant: ModelVariant) -> String {
        variant.sizeBytes > 0 ? DS.formatBytes(Int(variant.sizeBytes)) : String(localized: "Built in")
    }

    /// English-only models silently disable the language picker, so say so before the pick.
    static func badge(for variant: ModelVariant) -> String? {
        guard case .some(.only(let codes)) = variant.languageScope, codes == ["en"] else { return nil }
        return String(localized: "EN only")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Font.calloutMedium)
                .foregroundStyle(.secondary)
            TextField("Search models", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .axLeaf("ModelPicker.TextField.Search")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Font.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .axLeaf("ModelPicker.Button.ClearSearch")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
    }

    private var installedOnlyToggle: some View {
        Toggle(isOn: $installedOnly) {
            Text("Installed only")
                .font(.caption)
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
        if !isInstalled(variant) {
            model.downloadModel(variant.id)
        }
        model.activateModel(variant.id)
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
