import SwiftUI
import ParolaCore

struct QueueView: View {
    @EnvironmentObject var model: AppModel

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
        HStack {
            Text("Queue").font(DS.Font.title)
            Spacer()
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

    @ViewBuilder
    private var mainContent: some View {
        if model.batchJobs.isEmpty {
            empty
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.large) {
                    section(title: "In Progress", statuses: [.transcribing, .pending])
                    section(title: "Cancelled", statuses: [.cancelled])
                    section(title: "Failed", statuses: [.failed])
                    section(title: "Completed", statuses: [.done])
                }
                .padding(.horizontal, DS.Spacing.large)
                .padding(.vertical, DS.Spacing.medium)
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

    @ViewBuilder
    private func section(title: String, statuses: Set<BatchJob.Status>) -> some View {
        let jobs = model.batchJobs.filter { statuses.contains($0.status) }
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text(title.uppercased())
                    .font(.caption.weight(.medium))
                    .tracking(0.6)
                    .foregroundStyle(DS.Color.secondaryText)
                VStack(spacing: 1) {
                    ForEach(jobs) { job in
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
