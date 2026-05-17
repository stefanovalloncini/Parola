import SwiftUI
import ParolaCore

struct PromptsPane: View {
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .builtInFirst

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField
            sortRow

            SettingsSection {
                let visible = visiblePrompts
                if visible.isEmpty {
                    HStack {
                        Text("No prompts match.").foregroundStyle(.secondary).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, prompt in
                        SettingRow(prompt.name, isFirst: idx == 0) {
                            Text(prompt.isBuiltIn ? "Built-in" : "Custom").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            SettingHelper(text: "Prompts rewrite transcripts after recording — used by dictation cleanup and the Transcript menu.")
        }
    }

    private var visiblePrompts: [Prompt] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var prompts = Prompt.builtIns
        if !query.isEmpty {
            prompts = prompts.filter { $0.name.lowercased().contains(query) }
        }
        switch sortOption {
        case .builtInFirst:
            prompts.sort { lhs, rhs in
                if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn && !rhs.isBuiltIn }
                return false
            }
        case .nameAZ:
            prompts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameZA:
            prompts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
        return prompts
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search prompts…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var sortRow: some View {
        HStack {
            Spacer()
            Menu {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button {
                        sortOption = option
                    } label: {
                        if sortOption == option {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort prompts")
        }
    }

    enum SortOption: CaseIterable {
        case builtInFirst, nameAZ, nameZA

        var label: String {
            switch self {
            case .builtInFirst: return "Built-in first"
            case .nameAZ: return "Name A→Z"
            case .nameZA: return "Name Z→A"
            }
        }
    }
}
