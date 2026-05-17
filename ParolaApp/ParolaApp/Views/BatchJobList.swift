import SwiftUI
import UniformTypeIdentifiers
import ParolaCore

struct BatchJobList: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText = ""
    @State private var sortOrder: BatchSortOrder = .addedFirst

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.batchJobs.count) file\(model.batchJobs.count == 1 ? "" : "s")")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer()
                Button("Clear") { model.clearBatch() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(model.batchJobs.allSatisfy { $0.status == .transcribing })
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.top, DS.Spacing.regular)
            .padding(.bottom, DS.Spacing.small)

            HStack(spacing: DS.Spacing.small) {
                searchField
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
                                    BatchJobRow(job: job)
                                        .onTapGesture { model.selectBatchJob(job.id) }
                                }
                            }
                        }
                    } else {
                        ForEach(sorted(matches)) { job in
                            BatchJobRow(job: job)
                                .onTapGesture { model.selectBatchJob(job.id) }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.large)
                .padding(.bottom, DS.Spacing.large)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search files…", text: $searchText)
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

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                ForEach(BatchSortOrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .medium))
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
        .help("Sort: \(sortOrder.title)")
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
            return jobs.sorted { fileSize($0.url) > fileSize($1.url) }
        case .smallestFirst:
            return jobs.sorted { fileSize($0.url) < fileSize($1.url) }
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

enum BatchSortOrder: CaseIterable, Hashable {
    case addedFirst
    case addedLast
    case nameAsc
    case nameDesc
    case largestFirst
    case smallestFirst
    case status

    var title: String {
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
}

struct BatchStatusGroup {
    let status: BatchJob.Status
    let jobs: [BatchJob]

    var title: String {
        switch status {
        case .pending: return "Queued"
        case .transcribing: return "Transcribing"
        case .done: return "Complete"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

enum BatchMediaKind {
    case audio
    case video

    init(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            self = .audio
            return
        }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            self = .video
        } else {
            self = .audio
        }
    }
}

struct BatchJobRow: View {
    @EnvironmentObject var model: AppModel
    let job: BatchJob

    private var kind: BatchMediaKind { BatchMediaKind(url: job.url) }

    private var iconBackground: Color {
        switch kind {
        case .video: return Color(red: 0.30, green: 0.62, blue: 0.42)
        case .audio: return Color(red: 0.24, green: 0.62, blue: 0.66)
        }
    }

    private var iconSymbol: String {
        switch kind {
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        }
    }

    private var statusText: String {
        switch job.status {
        case .pending: return "Queued"
        case .transcribing:
            return job.progress > 0
                ? "Transcribing \(Int(job.progress * 100))%"
                : "Transcribing…"
        case .done: return "Complete"
        case .failed: return job.error ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .pending: return DS.Color.secondaryText
        case .transcribing: return DS.Color.accent
        case .done: return Color(red: 0.36, green: 0.66, blue: 0.46)
        case .failed: return DS.Color.danger
        case .cancelled: return DS.Color.secondaryText
        }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            iconSquare
            VStack(alignment: .leading, spacing: 6) {
                Text(job.url.lastPathComponent)
                    .font(DS.Font.body.weight(.medium))
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                progressBar
                Text(statusText)
                    .font(DS.Font.caption)
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: DS.Spacing.small)
            cancelButton
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.regular)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                        .strokeBorder(
                            model.selectedBatchJobID == job.id ? DS.Color.accent.opacity(0.5) : DS.Color.separator.opacity(0.4),
                            lineWidth: model.selectedBatchJobID == job.id ? 1.5 : 0.5
                        )
                )
        }
        .contentShape(Rectangle())
    }

    private var iconSquare: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(iconBackground)
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: iconSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    @ViewBuilder
    private var progressBar: some View {
        switch job.status {
        case .pending:
            EmptyView()
        case .transcribing:
            if job.progress > 0 {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .frame(height: 3)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .frame(height: 3)
            }
        case .done:
            ProgressView(value: 1)
                .progressViewStyle(.linear)
                .tint(statusColor)
                .frame(height: 3)
        case .failed:
            ProgressView(value: 1)
                .progressViewStyle(.linear)
                .tint(DS.Color.danger)
                .frame(height: 3)
        case .cancelled:
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .tint(DS.Color.secondaryText)
                .frame(height: 3)
        }
    }

    private var cancelButton: some View {
        Button {
            model.cancelBatchJob(job.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(DS.Color.separator.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .help(job.status == .transcribing ? "Cancel" : "Remove")
    }
}
