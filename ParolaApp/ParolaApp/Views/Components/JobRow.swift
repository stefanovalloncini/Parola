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
            return String(localized: "Transcribing · \(AppFormat.percent(job.progress))")
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

/// What a row's ✕ means: the Queue cancels the run, the Batch page cancels the one file.
struct JobCancelAction {
    let help: LocalizedStringKey
    let axID: String
    let run: () -> Void

    /// The Queue page's ✕, as `QueueRow` had it: one control for the whole run.
    static func wholeBatch(_ run: @escaping () -> Void) -> JobCancelAction {
        JobCancelAction(help: "Cancel Batch", axID: "Row.Button.CancelBatch", run: run)
    }

    /// The Batch page's ✕, as `BatchJobRow` had it: a running file is cancelled, a waiting one is removed.
    static func oneJob(status: BatchJob.Status, _ run: @escaping () -> Void) -> JobCancelAction {
        JobCancelAction(
            help: status == .transcribing ? "Cancel" : "Remove",
            axID: "Row.Button.Cancel",
            run: run
        )
    }
}

/// The one row a batch job draws, on the Queue page, on the Batch page and in the batch sidebar.
struct JobRow: View {
    let job: BatchJob
    var isSelected: Bool = false
    /// The sidebar's column is narrow: no progress bar and no trailing action, the status text alone.
    var compact: Bool = false
    var cancel: JobCancelAction?

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// Only the sidebar's selection is a solid accent fill; the pages wash theirs, where onAccent would vanish.
    private var onAccent: Bool { isSelected && compact }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            EntryBadge(kind: EntrySourceKind(url: job.url), onAccent: onAccent)
            VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                Text(job.url.lastPathComponent)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(onAccent ? DS.Color.onAccent : DS.Color.primaryText)
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
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
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
        .foregroundStyle(onAccent ? DS.Color.onAccent : BatchJobStatus.tint(for: job.status))
    }

    @ViewBuilder
    private var action: some View {
        switch job.status {
        case .pending, .transcribing:
            if let cancel {
                actionButton(cancel.help, systemImage: "xmark", axID: cancel.axID, action: cancel.run)
            }
        case .failed, .cancelled:
            actionButton("Retry", systemImage: "arrow.clockwise", axID: "Row.Button.Retry") {
                model.retryBatchJob(job.id)
            }
        case .done:
            actionButton("Open", systemImage: "doc.text", axID: "Row.Button.Open") {
                model.openBatchJobTranscript(job.id)
            }
        }
    }

    private func actionButton(
        _ help: LocalizedStringKey,
        systemImage: String,
        axID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(DSIconChipButtonStyle(side: 26))
        .help(help)
        .accessibilityLabel(Text(help))
        .axLeaf(axID)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected, !compact {
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
