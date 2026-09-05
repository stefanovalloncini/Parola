import SwiftUI
import ParolaCore

struct QueueView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .newestFirst
    @FocusState private var focusedJob: BatchJob.ID?

    enum SortOption: String, CaseIterable, Identifiable {
        case newestFirst = "Newest first"
        case oldestFirst = "Oldest first"
        case nameAscending = "Name A→Z"
        case nameDescending = "Name Z→A"
        case mostProgress = "Most progress"
        case leastProgress = "Least progress"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            mainContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.surface)
        .axBranch("Queue")
    }

    private var toolbar: some View {
        HStack(spacing: DS.Spacing.regular) {
            Text("Queue").font(DS.Font.title)
            Spacer()
            SearchPill(text: $searchText, placeholder: "Search queue")
                .frame(maxWidth: 240)
            sortMenu
            Button {
                model.clearFinishedBatchJobs()
            } label: {
                Text("Clear Finished")
                    .font(DS.Font.callout)
                    .padding(.horizontal, DS.Spacing.regular)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(DS.Color.surfaceElevated)
                    )
                    .overlay(
                        Capsule().strokeBorder(DS.Color.separator, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!hasFinishedJobs)
            .opacity(hasFinishedJobs ? 1 : 0.5)
            .axLeaf("Toolbar.Button.ClearFinished")
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.regular)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            DSIconChip(systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort jobs")
        .axLeaf("Toolbar.Menu.Sort")
    }

    @ViewBuilder
    private var mainContent: some View {
        if model.batchJobs.isEmpty {
            empty
        } else {
            let jobs = visibleJobs
            if jobs.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.large) {
                        section(title: "In Progress", jobs: jobs, statuses: [.transcribing, .pending])
                        section(title: "Cancelled", jobs: jobs, statuses: [.cancelled])
                        section(title: "Failed", jobs: jobs, statuses: [.failed])
                        section(title: "Completed", jobs: jobs, statuses: [.done])
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.vertical, DS.Spacing.medium)
                }
            }
        }
    }

    private var empty: some View {
        EmptyStateView(
            systemImage: "list.bullet.indent",
            title: "No Jobs Yet",
            message: "Batch transcriptions appear here. They stay until you clear them."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasFinishedJobs: Bool {
        model.batchJobs.contains { $0.status == .done || $0.status == .cancelled || $0.status == .failed }
    }

    private var visibleJobs: [BatchJob] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered: [BatchJob]
        if query.isEmpty {
            filtered = model.batchJobs
        } else {
            filtered = model.batchJobs.filter {
                $0.url.lastPathComponent.range(of: query, options: .caseInsensitive) != nil
            }
        }
        switch sortOption {
        case .newestFirst:
            // Jobs append oldest-first, so insertion order is oldest-first.
            return filtered.reversed()
        case .oldestFirst:
            return filtered
        case .nameAscending:
            return filtered.sorted {
                $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
        case .nameDescending:
            return filtered.sorted {
                $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedDescending
            }
        case .mostProgress:
            return filtered.sorted { $0.progress > $1.progress }
        case .leastProgress:
            return filtered.sorted { $0.progress < $1.progress }
        }
    }

    /// `statuses` is an order, not a set: In Progress lists the running job above the queued ones
    /// whatever the sort picked.
    @ViewBuilder
    private func section(title: String, jobs: [BatchJob], statuses: [BatchJob.Status]) -> some View {
        let matching = statuses.flatMap { status in jobs.filter { $0.status == status } }
        if !matching.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text(title.uppercased())
                    .font(DS.Font.captionMedium)
                    .tracking(0.6)
                    .foregroundStyle(DS.Color.secondaryText)
                VStack(spacing: 1) {
                    ForEach(matching) { job in
                        QueueRow(job: job, isFocused: focusedJob == job.id)
                            .focusable(true)
                            .focusEffectDisabled()
                            .focused($focusedJob, equals: job.id)
                            .onKeyPress(.return) {
                                handleReturn(job: job); return .handled
                            }
                            .onKeyPress(.delete) {
                                handleDelete(job: job); return .handled
                            }
                    }
                }
            }
        }
    }

    private func handleReturn(job: BatchJob) {
        switch job.status {
        case .done: model.openBatchJobTranscript(job.id)
        case .failed, .cancelled: model.retryBatchJob(job.id)
        case .pending, .transcribing: break
        }
    }

    private func handleDelete(job: BatchJob) {
        model.cancelBatchJob(job.id)
    }
}
