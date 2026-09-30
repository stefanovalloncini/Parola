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
            BatchImportNotices()
            mainContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.surface)
        .toolbarSearch(text: $searchText, for: .queue)
        .axBranch("Queue")
    }

    private var toolbar: some View {
        PageHeader(
            title: "Queue",
            subtitle: QueueCount.label(for: model.batchJobs),
            trailing: {
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
            .pickerStyle(.inline)
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

    /// Not while files are checked: the notice above says what is happening, and an empty state would invite a second drop.
    static func showsEmptyState(for model: AppModel) -> Bool {
        model.batchIsEmpty && model.batchFilesBeingChecked == 0
    }

    @ViewBuilder
    private var mainContent: some View {
        if model.batchIsEmpty {
            if Self.showsEmptyState(for: model) { empty } else { Spacer(minLength: 0) }
        } else {
            let sections = visibleSections
            if sections.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            SectionCaption(section.title)
                                .padding(.top, section.id == sections.first?.id ? 0 : DS.Spacing.large)
                                .padding(.bottom, DS.Spacing.small)
                            ForEach(section.jobs) { job in
                                jobRow(job)
                                if job.id != section.jobs.last?.id {
                                    Divider()
                                        .padding(.leading, DS.Spacing.small + EntryRowMetrics.textInset)
                                }
                            }
                        }
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
            .axLeaf("Button.AddFiles")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .axBranch("Empty")
    }

    private var hasFinishedJobs: Bool {
        model.batchBuckets.hasFinished
    }

    private struct JobSection: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let jobs: [BatchJob]
    }

    /// `statuses` is an order, not a set: In Progress lists the running job first whatever the sort picked.
    private static let layout: [(id: String, title: LocalizedStringKey, statuses: [BatchJob.Status])] = [
        ("inProgress", "In Progress", [.transcribing, .pending]),
        ("cancelled", "Cancelled", [.cancelled]),
        ("failed", "Failed", [.failed]),
        ("completed", "Completed", [.done]),
    ]

    private var visibleSections: [JobSection] {
        let buckets = model.batchBuckets
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return Self.layout.compactMap { layout in
            let jobs = layout.statuses.flatMap { sorted(matching(buckets.jobs($0), query: query)) }
            return jobs.isEmpty ? nil : JobSection(id: layout.id, title: layout.title, jobs: jobs)
        }
    }

    private func matching(_ jobs: [BatchJob], query: String) -> [BatchJob] {
        guard !query.isEmpty else { return jobs }
        return jobs.filter { $0.url.lastPathComponent.range(of: query, options: .caseInsensitive) != nil }
    }

    private func sorted(_ jobs: [BatchJob]) -> [BatchJob] {
        switch sortOption {
        case .newestFirst:
            // Jobs append oldest-first, so insertion order is oldest-first.
            return jobs.reversed()
        case .oldestFirst:
            return jobs
        case .nameAscending:
            return jobs.sorted {
                $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
        case .nameDescending:
            return jobs.sorted {
                $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedDescending
            }
        case .mostProgress:
            return jobs.sorted { model.batchProgress.fraction(for: $0.id) > model.batchProgress.fraction(for: $1.id) }
        case .leastProgress:
            return jobs.sorted { model.batchProgress.fraction(for: $0.id) < model.batchProgress.fraction(for: $1.id) }
        }
    }

    private func jobRow(_ job: BatchJob) -> some View {
        JobRow(job: job, isSelected: focusedJob == job.id, cancel: .wholeBatch)
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
                let exports = (model.batchSidecars[job.id] ?? [])
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
