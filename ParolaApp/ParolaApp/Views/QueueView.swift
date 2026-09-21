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
        PageHeader(
            title: "Queue",
            subtitle: QueueCount.label(for: model.batchJobs),
            trailing: {
                CollapsingSearchPill(text: $searchText, placeholder: "Search queue", leaf: "Toolbar.TextField.Search", width: 240)
                sortMenu
                Button {
                    model.clearFinishedBatchJobs()
                } label: {
                    Text("Clear Finished")
                }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .disabled(!hasFinishedJobs)
                .axLeaf("Toolbar.Button.ClearFinished")
            }
        )
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(DSIconChipButtonStyle(side: 26))
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
            message: "Queued transcriptions appear here. They stay until you clear them."
        ) {
            Button {
                model.presentBatchOpenPanel()
            } label: {
                Text("Add Files…")
            }
            .buttonStyle(DSPillButtonStyle(kind: .primary))
            .axLeaf("Empty.Button.AddFiles")
        }
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

    /// `statuses` is an order, not a set: In Progress lists the running job first whatever the sort picked.
    @ViewBuilder
    private func section(title: LocalizedStringKey, jobs: [BatchJob], statuses: [BatchJob.Status]) -> some View {
        let matching = statuses.flatMap { status in jobs.filter { $0.status == status } }
        if !matching.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                SectionCaption(title)
                VStack(spacing: 0) {
                    ForEach(matching) { job in
                        jobRow(job)
                        if job.id != matching.last?.id {
                            Divider()
                                .padding(.leading, DS.Spacing.small + EntryRowMetrics.textInset)
                        }
                    }
                }
            }
        }
    }

    private func jobRow(_ job: BatchJob) -> some View {
        JobRow(
            job: job,
            isSelected: focusedJob == job.id,
            cancel: .wholeBatch { model.cancelAllInFlightBatchJobs() }
        )
            .focusable(true)
            .focusEffectDisabled()
            .focused($focusedJob, equals: job.id)
            .onKeyPress(.return) {
                handleReturn(job: job); return .handled
            }
            .onKeyPress(.delete) {
                handleDelete(job: job); return .handled
            }
            .contextMenu {
                switch job.status {
                case .pending, .transcribing:
                    Button("Cancel Batch") { model.cancelAllInFlightBatchJobs() }
                        .axLeaf("Row.ContextMenuItem.CancelBatch")
                case .failed, .cancelled:
                    Button("Retry") { model.retryBatchJob(job.id) }
                        .axLeaf("Row.ContextMenuItem.Retry")
                case .done:
                    Button("Open") { model.openBatchJobTranscript(job.id) }
                        .axLeaf("Row.ContextMenuItem.Open")
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([job.url])
                    }
                    .axLeaf("Row.ContextMenuItem.RevealInFinder")
                }
            }
            .onDrag {
                guard case .done = job.status else { return NSItemProvider() }
                let exports = model.batchExportPresets
                    .map { job.url.deletingPathExtension().appendingPathExtension($0.spec.format.fileExtension) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                return NSItemProvider(object: (exports.first ?? job.url) as NSURL)
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
