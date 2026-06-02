import SwiftUI
import ParolaCore

struct LibraryListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: LibraryEntry.ID?
    @State private var category: EntryCategory?
    @State private var sortOrder: SortOrder = .newestFirst
    @State private var displayed: [LibraryEntry] = []
    @State private var grouped: [EntryCategory: [LibraryEntry]] = [:]

    enum SortOrder: String, CaseIterable, Identifiable {
        case newestFirst
        case oldestFirst
        case titleAscending
        case titleDescending

        var id: String { rawValue }

        var label: String {
            switch self {
            case .newestFirst: return "Newest first"
            case .oldestFirst: return "Oldest first"
            case .titleAscending: return "Title A→Z"
            case .titleDescending: return "Title Z→A"
            }
        }
    }

    private func recompute() {
        let base = model.searchResults ?? model.libraryEntries
        let filtered = category.map { c in base.filter { $0.category == c } } ?? base
        let sorted = sort(filtered)
        displayed = sorted
        grouped = Dictionary(grouping: sorted, by: \.category)
    }

    private func sort(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        switch sortOrder {
        case .newestFirst:
            return entries.sorted { $0.createdAt > $1.createdAt }
        case .oldestFirst:
            return entries.sorted { $0.createdAt < $1.createdAt }
        case .titleAscending:
            return entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDescending:
            return entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        }
    }

    private var isSearching: Bool { model.searchResults != nil }

    var body: some View {
        VStack(spacing: 0) {
            filterChips
            content
        }
        .toolbar { sortMenu }
        .onAppear { recompute() }
        .onChange(of: model.libraryEntries) { _, _ in recompute() }
        .onChange(of: model.searchResults) { _, _ in recompute() }
        .onChange(of: category) { _, _ in recompute() }
        .onChange(of: sortOrder) { _, _ in recompute() }
    }

    @ViewBuilder
    private var content: some View {
        if displayed.isEmpty {
            if isSearching {
                ContentUnavailableView.search
            } else if category != nil {
                ContentUnavailableView(
                    "No entries in this category",
                    systemImage: "tray",
                    description: Text("Pick another filter to see more.")
                )
            } else {
                EmptyLibraryView()
            }
        } else {
            List(selection: $selection) {
                ForEach(EntryCategory.allCases, id: \.self) { category in
                    if let entries = grouped[category], !entries.isEmpty {
                        Section(Self.label(for: category)) {
                            ForEach(entries) { entry in
                                row(entry).tag(entry.id)
                            }
                            .onDelete { offsets in
                                let ids = offsets.map { entries[$0].id }
                                for id in ids { model.deleteEntry(id) }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(label: "All", value: nil)
                ForEach(EntryCategory.allCases, id: \.self) { c in
                    chip(label: Self.label(for: c), value: c)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func chip(label: String, value: EntryCategory?) -> some View {
        let selected = category == value
        return Button(label) {
            category = value
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .tint(selected ? .accentColor : .secondary)
    }

    @ToolbarContentBuilder
    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel(Text("Sort"))
        }
    }

    private static func label(for category: EntryCategory) -> String {
        switch category {
        case .transcription: return "Transcriptions"
        case .meeting: return "Meetings"
        case .dictation: return "Dictations"
        }
    }

    private func row(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title).font(.body.weight(.medium))
            HStack(spacing: 8) {
                Text(entry.createdAt, style: .date)
                Text("·")
                Text(entry.manifest.modelName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyLibraryView: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating, value: pulse)
                .shadow(color: Color.accentColor.opacity(0.18), radius: 18, x: 0, y: 6)
            VStack(spacing: 8) {
                Text("library.empty.title")
                    .font(.title3.weight(.semibold))
                Text("library.empty.body")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !reduceMotion { pulse = true } }
    }
}
