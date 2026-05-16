import SwiftUI
import ParolaCore

struct MacLibrarySidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText = ""
    @State private var selectedRoute: SidebarRoute = .home
    @State private var showingTrash = false

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(
                        title: "Home",
                        systemImage: "house.fill",
                        isSelected: selectedRoute == .home
                    ) {
                        selectedRoute = .home
                        model.route = .transcript
                    }

                    SidebarRow(
                        title: "Queue",
                        systemImage: "list.bullet.indent",
                        isSelected: selectedRoute == .queue,
                        badge: activeQueueBadge
                    ) {
                        selectedRoute = .queue
                        model.route = .queue
                    }

                    SectionLabel("History").padding(.top, 14)

                    SidebarRow(
                        title: "Transcriptions",
                        systemImage: "text.alignleft",
                        isSelected: selectedRoute == .category(.transcription)
                    ) { selectedRoute = .category(.transcription) }

                    SidebarRow(
                        title: "Meetings",
                        systemImage: "person.2.fill",
                        isSelected: selectedRoute == .category(.meeting)
                    ) { selectedRoute = .category(.meeting) }

                    SidebarRow(
                        title: "Dictations",
                        systemImage: "text.cursor",
                        isSelected: selectedRoute == .category(.dictation)
                    ) { selectedRoute = .category(.dictation) }

                    SidebarRow(
                        title: "Recently Deleted",
                        systemImage: "trash",
                        isSelected: selectedRoute == .recentlyDeleted
                    ) {
                        selectedRoute = .recentlyDeleted
                        showingTrash = true
                    }

                    SectionLabel("People").padding(.top, 14)

                    SidebarRow(
                        title: "Add People",
                        systemImage: "person.fill.badge.plus",
                        isSelected: selectedRoute == .addPeople
                    ) {
                        if model.transcript != nil {
                            selectedRoute = .addPeople
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
        .sheet(isPresented: $showingTrash, onDismiss: {
            if selectedRoute == .recentlyDeleted { selectedRoute = .home }
        }) {
            MacRecentlyDeletedView()
        }
        .onChange(of: searchText) { _, newValue in model.search(newValue) }
    }

    private var activeQueueBadge: Int? {
        let n = model.batchJobs.filter { $0.status == .pending || $0.status == .transcribing }.count
        return n > 0 ? n : nil
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search history…", text: $searchText)
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

    private var bottomPills: some View {
        VStack(spacing: 6) {
            PillRow(title: "Support", systemImage: "questionmark.circle.fill") { }

            SettingsLink {
                PillRowContent(title: "Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(.plain)
        }
    }
}

private enum SidebarRoute: Hashable {
    case home
    case queue
    case category(EntryCategory)
    case recentlyDeleted
    case addPeople
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

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

private struct PillRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PillRowContent(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
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
