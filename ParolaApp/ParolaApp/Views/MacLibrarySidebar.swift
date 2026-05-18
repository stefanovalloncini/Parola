import SwiftUI
import ParolaCore

struct MacLibrarySidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText = ""

    private var selectedRoute: SidebarRoute {
        switch model.route {
        case .queue: return .queue
        case .batch: return .batch
        case .transcript:
            if let filter = model.libraryFilter { return .category(filter) }
            return .home
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchPill(text: $searchText, placeholder: "Search history…")
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            filterRow
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(
                        title: "Home",
                        systemImage: "house.fill",
                        isSelected: selectedRoute == .home,
                        badge: pinnedBadge
                    ) {
                        model.libraryFilter = nil
                        model.route = .transcript
                    }

                    SidebarRow(
                        title: "Queue",
                        systemImage: "list.bullet.indent",
                        isSelected: selectedRoute == .queue,
                        badge: activeQueueBadge
                    ) {
                        model.libraryFilter = nil
                        model.route = .queue
                    }

                    SidebarRow(
                        title: "Recently Deleted",
                        systemImage: "trash",
                        isSelected: model.showingTrash
                    ) {
                        model.showingTrash = true
                    }

                    SectionLabel("People").padding(.top, 14)

                    SidebarRow(
                        title: "Add People",
                        systemImage: "person.fill.badge.plus",
                        isSelected: model.showingSpeakersSheet
                    ) {
                        if model.transcript != nil {
                            model.showingSpeakersSheet = true
                        }
                    }
                    .disabled(model.transcript == nil)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Spacer(minLength: 0)

            bottomPills
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        .onChange(of: searchText) { _, newValue in model.search(newValue) }
    }

    private var activeQueueBadge: Int? {
        let n = model.batchJobs.filter { $0.status == .pending || $0.status == .transcribing }.count
        return n > 0 ? n : nil
    }

    private var pinnedBadge: Int? {
        let n = model.libraryEntries.filter { $0.pinned }.count
        return n > 0 ? n : nil
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    FilterChip(title: "All", isSelected: model.libraryFilter == nil) {
                        model.libraryFilter = nil
                    }
                    FilterChip(title: "Transcriptions", isSelected: model.libraryFilter == .transcription) {
                        model.libraryFilter = .transcription
                    }
                    FilterChip(title: "Meetings", isSelected: model.libraryFilter == .meeting) {
                        model.libraryFilter = .meeting
                    }
                    FilterChip(title: "Dictations", isSelected: model.libraryFilter == .dictation) {
                        model.libraryFilter = .dictation
                    }
                }
            }
            sortMenu
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $model.librarySortOrder) {
                ForEach(LibrarySortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DS.Color.surfaceElevated)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
    }

    private var bottomPills: some View {
        SettingsLink {
            PillRowContent(title: "Settings", systemImage: "gearshape.fill")
        }
        .buttonStyle(.plain)
    }
}

private enum SidebarRoute: Hashable {
    case home
    case queue
    case batch
    case category(EntryCategory)
}

private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var badge: Int? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text("\(badge)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(
                                isSelected
                                    ? Color.white.opacity(0.18)
                                    : Color.primary.opacity(0.10)
                            )
                        )
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.85))
        } else if isHovering {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous).fill(background)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isSelected { return DS.Color.accent.opacity(0.85) }
        if isHovering { return DS.Color.surfaceElevated }
        return Color.primary.opacity(0.06)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

private struct PillRowContent: View {
    let title: String
    let systemImage: String

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18, alignment: .center)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
