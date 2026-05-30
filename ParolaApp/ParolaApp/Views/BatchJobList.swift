import SwiftUI
import ParolaCore

struct BatchJobList: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var sortOrder: BatchSortOrder = .addedFirst
    @FocusState private var focusedJob: BatchJob.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Group {
                    if model.batchJobs.count == 1 {
                        Text("1 file")
                    } else {
                        Text("\(model.batchJobs.count) files")
                    }
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                Spacer()
                Button("Clear") { model.clearBatch() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(model.batchJobs.allSatisfy { $0.status == .transcribing })
                    .axLeaf("Queue.Button.Clear")
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.top, DS.Spacing.regular)
            .padding(.bottom, DS.Spacing.small)

            HStack(spacing: DS.Spacing.small) {
                SearchPill(text: $searchText, placeholder: "Search files…")
                sortMenu
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.bottom, DS.Spacing.small)

            jobsScroll

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button {
                    model.presentBatchOpenPanel()
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .axLeaf("Queue.Button.AddFiles")
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.bottom, DS.Spacing.regular)
        }
    }

    @ViewBuilder
    private var jobsScroll: some View {
        let matches = filteredJobs
        if matches.isEmpty && !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: DS.Spacing.small) {
                    if sortOrder == .status {
                        ForEach(statusGroups(from: matches), id: \.status) { group in
                            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                                Text(group.title)
                                    .font(DS.Font.caption.weight(.semibold))
                                    .foregroundStyle(DS.Color.secondaryText)
                                    .padding(.top, DS.Spacing.small)
                                ForEach(group.jobs) { job in
                                    rowWithKeyboardSupport(job: job)
                                }
                            }
                        }
                    } else {
                        ForEach(sorted(matches)) { job in
                            rowWithKeyboardSupport(job: job)
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.large)
                .padding(.bottom, DS.Spacing.large)
            }
        }
    }

    private func rowWithKeyboardSupport(job: BatchJob) -> some View {
        let isPending = job.status == .pending
        return BatchJobRow(job: job)
            .focusable(true)
            .focusEffectDisabled()
            .focused($focusedJob, equals: job.id)
            .onTapGesture { model.selectBatchJob(job.id) }
            .onKeyPress(.return) { model.selectBatchJob(job.id); return .handled }
            .onKeyPress(.delete) { model.cancelBatchJob(job.id); return .handled }
            .modifier(PendingBatchJobReorder(jobID: job.id, isPending: isPending))
            .contextMenu {
                if isPending {
                    Button("Move to top") { model.moveBatchJobToTop(job.id) }
                        .axLeaf("Row.ContextMenuItem.MoveToTop")
                }
                if job.status == .done {
                    Button("Open transcript") { model.openBatchJobTranscript(job.id) }
                        .axLeaf("Row.ContextMenuItem.OpenTranscript")
                }
                Button(job.status == .transcribing ? "Cancel" : "Remove", role: .destructive) {
                    model.cancelBatchJob(job.id)
                }
                .axLeaf("Row.ContextMenuItem.CancelOrRemove")
            }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                ForEach(BatchSortOrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(DS.Font.calloutMedium)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: \(sortOrder.localizedTitle)")
        .axLeaf("Queue.Menu.Sort")
    }

    private var filteredJobs: [BatchJob] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.batchJobs }
        return model.batchJobs.filter {
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
    }

    private func sorted(_ jobs: [BatchJob]) -> [BatchJob] {
        switch sortOrder {
        case .addedFirst, .status:
            return jobs
        case .addedLast:
            return jobs.reversed()
        case .nameAsc:
            return jobs.sorted {
                $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
        case .nameDesc:
            return jobs.sorted {
                $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedDescending
            }
        case .largestFirst:
            let sizes = jobs.reduce(into: [BatchJob.ID: Int]()) { $0[$1.id] = fileSize($1.url) }
            return jobs.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
        case .smallestFirst:
            let sizes = jobs.reduce(into: [BatchJob.ID: Int]()) { $0[$1.id] = fileSize($1.url) }
            return jobs.sorted { (sizes[$0.id] ?? 0) < (sizes[$1.id] ?? 0) }
        }
    }

    private func statusGroups(from jobs: [BatchJob]) -> [BatchStatusGroup] {
        let order: [BatchJob.Status] = [.transcribing, .pending, .done, .failed, .cancelled]
        return order.compactMap { status in
            let bucket = jobs.filter { $0.status == status }
            guard !bucket.isEmpty else { return nil }
            return BatchStatusGroup(status: status, jobs: bucket)
        }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

private struct PendingBatchJobReorder: ViewModifier {
    let jobID: BatchJob.ID
    let isPending: Bool
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if isPending {
            content
                .draggable(BatchJobDragPayload(jobID: jobID))
                .dropDestination(for: BatchJobDragPayload.self) { items, _ in
                    guard let payload = items.first else { return false }
                    model.moveBatchJob(payload.jobID, before: jobID)
                    return true
                } isTargeted: { isTargeted = $0 }
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: DS.Radius.regular)
                            .strokeBorder(DS.Color.accent, lineWidth: 2)
                    }
                }
        } else {
            content
        }
    }
}

struct BatchJobDragPayload: Codable, Transferable {
    let jobID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

enum BatchSortOrder: CaseIterable, Hashable {
    case addedFirst
    case addedLast
    case nameAsc
    case nameDesc
    case largestFirst
    case smallestFirst
    case status

    var title: LocalizedStringKey {
        switch self {
        case .addedFirst: return "Added first"
        case .addedLast: return "Added last"
        case .nameAsc: return "Name A→Z"
        case .nameDesc: return "Name Z→A"
        case .largestFirst: return "Largest first"
        case .smallestFirst: return "Smallest first"
        case .status: return "Status"
        }
    }

    var localizedTitle: String {
        switch self {
        case .addedFirst: return String(localized: "Added first")
        case .addedLast: return String(localized: "Added last")
        case .nameAsc: return String(localized: "Name A→Z")
        case .nameDesc: return String(localized: "Name Z→A")
        case .largestFirst: return String(localized: "Largest first")
        case .smallestFirst: return String(localized: "Smallest first")
        case .status: return String(localized: "Status")
        }
    }
}

struct BatchStatusGroup {
    let status: BatchJob.Status
    let jobs: [BatchJob]

    var title: String {
        switch status {
        case .pending: return String(localized: "Queued")
        case .transcribing: return String(localized: "Transcribing")
        case .done: return String(localized: "Complete")
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}
