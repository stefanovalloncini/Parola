import SwiftUI
import ParolaCore

struct ModelManagerView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var filter: ModelFilter = .all

    var body: some View {
        let matches = filtered

        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ModelFilter.allCases) { option in
                            chip(option)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if matches.isEmpty {
                Section {
                    ContentUnavailableView
                        .search(text: query)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(matches) { entry in
                        row(entry)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search models")
        .navigationTitle(Text("settings.modelsOnDevice"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var filtered: [ModelInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.availableModels.filter { entry in
            guard filter.matches(entry) else { return false }
            guard !trimmed.isEmpty else { return true }
            let needle = trimmed.lowercased()
            return entry.label.lowercased().contains(needle)
                || entry.name.lowercased().contains(needle)
        }
    }

    @ViewBuilder
    private func chip(_ option: ModelFilter) -> some View {
        let selected = filter == option
        Button {
            filter = option
        } label: {
            Text(option.title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.15))
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ entry: ModelInfo) -> some View {
        HStack {
            Image(systemName: entry.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(entry.isInstalled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                if let size = entry.approximateSizeBytes {
                    Text(Self.humanBytes(size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.isInstalled {
                Button(role: .destructive) {
                    model.deleteModel(entry.name)
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    private static func humanBytes(_ bytes: Int) -> String {
        Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .file))
    }
}

enum ModelFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case installed
    case available
    case englishOnly
    case multilingual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .installed: return "Installed"
        case .available: return "Available"
        case .englishOnly: return "English-only"
        case .multilingual: return "Multilingual"
        }
    }

    func matches(_ info: ModelInfo) -> Bool {
        switch self {
        case .all: return true
        case .installed: return info.isInstalled
        case .available: return !info.isInstalled
        case .englishOnly: return !info.isMultilingual
        case .multilingual: return info.isMultilingual
        }
    }
}
