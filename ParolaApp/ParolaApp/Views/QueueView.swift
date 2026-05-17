import SwiftUI
import ParolaCore

struct QueueView: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .newestFirst

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
    }

    private var toolbar: some View {
        HStack(spacing: DS.Spacing.regular) {
            Text("Queue").font(DS.Font.title)
            Spacer()
            searchField
                .frame(maxWidth: 240)
            sortMenu
            Button {
                model.clearFinishedBatchJobs()
            } label: {
                Text("Clear Finished")
                    .font(.callout)
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
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.regular)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search queue", text: $searchText)
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
            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort jobs")
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
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.vertical, DS.Spacing.medium)
                }
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView(
            "No jobs yet",
            systemImage: "list.bullet.indent",
            description: Text("Files you transcribe in batch show up here while they run, then stay until you clear them.")
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
            return filtered
        case .oldestFirst:
            return filtered.reversed()
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

    @ViewBuilder
    private func section(title: String, jobs: [BatchJob], statuses: Set<BatchJob.Status>) -> some View {
        let matching = jobs.filter { statuses.contains($0.status) }
        if !matching.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text(title.uppercased())
                    .font(.caption.weight(.medium))
                    .tracking(0.6)
                    .foregroundStyle(DS.Color.secondaryText)
                VStack(spacing: 1) {
                    ForEach(matching) { job in
                        QueueRow(job: job)
                    }
                }
            }
        }
    }
}

private struct QueueRow: View {
    let job: BatchJob
    @EnvironmentObject var model: AppModel
    @State private var hovered = false

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            iconSquare
            VStack(alignment: .leading, spacing: 2) {
                Text(job.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsProgressBar {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .tint(DS.Color.accent)
                        .frame(maxWidth: 320)
                        .padding(.top, 2)
                }
            }
            Spacer()
            if hovered { trailingActions }
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular)
                .fill(DS.Color.surfaceElevated)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private var iconSquare: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.small)
                .fill(iconTint.opacity(0.22))
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconTint)
        }
        .frame(width: 32, height: 32)
    }

    private var iconTint: Color {
        isVideo ? .green : .teal
    }

    private var iconName: String {
        isVideo ? "film" : "waveform"
    }

    private var isVideo: Bool {
        let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]
        return videoExts.contains(job.url.pathExtension.lowercased())
    }

    private var showsProgressBar: Bool {
        switch job.status {
        case .pending, .transcribing: return true
        default: return false
        }
    }

    private var statusLine: String {
        let percent = Int((job.progress * 100).rounded())
        switch job.status {
        case .pending:
            return "Queued"
        case .transcribing:
            return percent > 0 ? "Transcribing… \(percent)%" : "Transcribing…"
        case .cancelled:
            let fraction = job.progress.formatted(.percent.precision(.fractionLength(1)))
            return "Progress: \(fraction) – Cancelled"
        case .failed:
            return "Failed: \(job.error ?? "unknown reason")"
        case .done:
            let segments = job.transcript?.segments.count ?? 0
            return "Completed · \(segments) segments"
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        switch job.status {
        case .pending, .transcribing:
            actionButton("Cancel batch", systemImage: "xmark.circle.fill") {
                model.cancelAllInFlightBatchJobs()
            }
        case .failed, .cancelled:
            actionButton("Retry", systemImage: "arrow.clockwise.circle.fill") {
                model.retryBatchJob(job.id)
            }
        case .done:
            actionButton("Open", systemImage: "doc.text") {
                model.openBatchJobTranscript(job.id)
            }
        }
    }

    private func actionButton(_ help: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(DS.Color.secondaryText)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
