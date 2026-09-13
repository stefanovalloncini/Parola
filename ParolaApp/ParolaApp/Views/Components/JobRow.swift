import SwiftUI
import ParolaCore

/// What a job says about itself: one line of status, wherever the job is rendered.
enum BatchJobStatus {
    static func text(for job: BatchJob) -> String {
        switch job.status {
        case .pending:
            return String(localized: "Queued")
        case .transcribing:
            // Under a percent the rounding would print "0%", which reads as stuck rather than starting.
            guard job.progress >= 0.01 else { return String(localized: "Transcribing…") }
            return String(localized: "Transcribing \(AppFormat.percent(job.progress))")
        case .cancelled:
            return String(localized: "Cancelled")
        case .failed:
            guard let error = job.error, !error.isEmpty else { return String(localized: "Failed") }
            return String(localized: "Failed: \(error)")
        case .done:
            return String(localized: "Completed · \(SegmentCount.label(job.transcript?.segments.count ?? 0))")
        }
    }

    static func symbol(for status: BatchJob.Status) -> String? {
        switch status {
        case .pending: return "clock"
        case .transcribing: return nil
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    static func tint(for status: BatchJob.Status) -> Color {
        switch status {
        case .pending: return DS.Color.secondaryText
        case .transcribing: return DS.Color.accentText
        case .done: return DS.Color.successText
        case .failed: return DS.Color.dangerText
        case .cancelled: return DS.Color.secondaryText
        }
    }

    /// Only a job that is actually running: a bar under "Queued" reads as work that has started.
    static func showsProgress(_ status: BatchJob.Status) -> Bool {
        status == .transcribing
    }
}

/// The one row a batch job draws, on the Queue page, on the Batch page and in the batch sidebar.
struct JobRow: View {
    let job: BatchJob
    var isSelected: Bool = false
    /// The sidebar's column is narrow: no progress bar and no trailing action, the status text alone.
    var compact: Bool = false

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            EntryBadge(kind: EntrySourceKind(url: job.url), isSelected: isSelected)
            VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                Text(job.url.lastPathComponent)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine
                if !compact, BatchJobStatus.showsProgress(job.status) {
                    DSProgressBar(value: job.progress > 0 ? job.progress : nil)
                        .padding(.top, DS.Spacing.hair)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                action
                    .opacity(isHovering ? 1 : 0.6)
            }
        }
        .padding(.vertical, compact ? DS.Spacing.tight : DS.Spacing.small)
        .padding(.horizontal, compact ? 0 : DS.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : DS.Motion.rowState, value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var statusLine: some View {
        HStack(spacing: DS.Spacing.tight) {
            if let symbol = BatchJobStatus.symbol(for: job.status) {
                Image(systemName: symbol)
                    .font(DS.Font.secondary)
            }
            Text(BatchJobStatus.text(for: job))
                .font(DS.Font.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(BatchJobStatus.tint(for: job.status))
    }

    @ViewBuilder
    private var action: some View {
        switch job.status {
        case .pending, .transcribing:
            actionButton("Cancel Batch", systemImage: "xmark") {
                model.cancelAllInFlightBatchJobs()
            }
        case .failed, .cancelled:
            actionButton("Retry", systemImage: "arrow.clockwise") {
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
        }
        .buttonStyle(DSIconChipButtonStyle(side: 26))
        .help(help)
        .accessibilityLabel(help)
        .axLeaf("Row.Button.\(help.replacingOccurrences(of: " ", with: ""))")
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Color.accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .strokeBorder(DS.Color.accent.opacity(0.35), lineWidth: 1)
                )
        } else if isHovering {
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Palette.surfaceHover)
        }
    }
}
