import SwiftUI
import ParolaCore

struct QueueView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .newestFirst
    @State private var selection: Set<BatchJob.ID> = []
    @State private var confirmingCancelAll = false

    enum SortOption: String, CaseIterable, Identifiable {
        case newestFirst = "Newest First"
        case oldestFirst = "Oldest First"
        case nameAscending = "Name A→Z"
        case nameDescending = "Name Z→A"
        case mostProgress = "Most Progress"
        case leastProgress = "Least Progress"

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
        .focusedSceneValue(\.pageListMenus, .queue(sort: $sortOption))
        .confirmationDialog(QueueCopy.cancelAllTitle(QueueCount.count(for: model.batchJobs)), isPresented: $confirmingCancelAll) {
            Button("Cancel All", role: .destructive) { model.cancelAllInFlightBatchJobs() }
            Button("Keep Transcribing", role: .cancel) {}
        } message: {
            Text("They stay in the list, and Retry starts them again.")
        }
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
                if model.canResumeBatch {
                    Button {
                        model.resumePendingBatchJobs()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                    .help("Continue transcribing the queued files.")
                    .axLeaf("Toolbar.Button.Resume")
                }
            }
        )
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(LocalizedStringKey(option.rawValue)).tag(option)
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
        .help("Sort")
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
                ContentUnavailableView.search
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(sections)
            }
        }
    }

    private func list(_ sections: [JobSection]) -> some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.jobs) { job in
                        jobRow(job)
                    }
                } header: {
                    SectionCaption(section.title)
                        .listRowInsets(EdgeInsets(
                            top: section.id == sections.first?.id ? 0 : DS.Spacing.regular,
                            leading: DS.Spacing.small,
                            bottom: DS.Spacing.tight,
                            trailing: DS.Spacing.small
                        ))
                }
            }
        }
        .listStyle(.inset)
        .tint(DS.Color.accentFill)
        .onDeleteCommand { model.deleteBatchJobs(selection) }
        .contextMenu(forSelectionType: BatchJob.ID.self) { ids in
            QueueRowMenu(model: model, ids: ids) { confirmingCancelAll = true }
        } primaryAction: { ids in
            model.openOrRetryBatchJobs(ids)
        }
    }

    private var empty: some View {
        EmptyStateView(
            systemImage: "list.bullet.indent",
            title: "Nothing Queued",
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
        JobRow(job: job, isSelected: selection.contains(job.id), listed: true, cancel: .oneJob(status: job.status))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .onDrag {
                guard case .done = job.status else { return NSItemProvider() }
                let exports = (model.batchSidecars[job.id] ?? [])
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                return Self.dragProvider(for: exports.first ?? job.url)
            }
    }

    static func dragProvider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        RowDrag.mark(provider)
        return provider
    }

}

/// The right-click menu for the rows it was opened on: the selection when the clicked row is in it.
struct QueueRowMenu: View {
    let model: AppModel
    let ids: Set<BatchJob.ID>
    let cancelAll: () -> Void

    var body: some View {
        let jobs = model.batchJobs.filter { ids.contains($0.id) }
        let done = jobs.filter { $0.status == .done }
        let retryable = jobs.filter { $0.status == .failed || $0.status == .cancelled }
        let waiting = jobs.filter { $0.status == .pending }
        let running = jobs.filter { $0.status == .transcribing }
        if jobs.count == 1, let job = done.first {
            Button("Open") { model.openBatchJobTranscript(job.id) }
                .axLeaf("Row.ContextMenuItem.Open")
        }
        if !done.isEmpty {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(done.map(\.url)) }
                .axLeaf("Row.ContextMenuItem.RevealInFinder")
        }
        if !retryable.isEmpty {
            Button("Retry") { model.retryBatchJobs(Set(retryable.map(\.id))) }
                .axLeaf("Row.ContextMenuItem.Retry")
        }
        if !waiting.isEmpty {
            Button("Remove") { model.deleteBatchJobs(Set(waiting.map(\.id))) }
                .axLeaf("Row.ContextMenuItem.Remove")
        }
        if !running.isEmpty {
            Button("Cancel") { model.deleteBatchJobs(Set(running.map(\.id))) }
                .axLeaf("Row.ContextMenuItem.Cancel")
        }
        if model.batchJobs.contains(where: { $0.status == .pending || $0.status == .transcribing }) {
            if !jobs.isEmpty { Divider() }
            Button("Cancel All…", action: cancelAll)
                .axLeaf("Row.ContextMenuItem.CancelAll")
        }
    }
}

enum QueueCopy {
    static func cancelAllTitle(_ count: Int, bundle: Bundle = .main) -> String {
        count == 1
            ? String(localized: "Cancel 1 transcription?", bundle: bundle)
            : String(localized: "Cancel \(count) transcriptions?", bundle: bundle)
    }
}
