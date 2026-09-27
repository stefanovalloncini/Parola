import SwiftUI
import ParolaCore

/// What a job says about itself: one line of status, wherever the job is rendered.
enum BatchJobStatus {
    static func text(status: BatchJob.Status, progress: Double, error: String?, segmentCount: Int) -> String {
        switch status {
        case .pending:
            return String(localized: "Queued")
        case .transcribing:
            // Under a percent the rounding would print "0%", which reads as stuck rather than starting.
            guard progress >= 0.01 else { return String(localized: "Transcribing…") }
            return String(localized: "Transcribing · \(AppFormat.percent(progress))")
        case .cancelled:
            return String(localized: "Cancelled")
        case .failed:
            guard let error, !error.isEmpty else { return String(localized: "Failed") }
            return String(localized: "Failed: \(error)")
        case .done:
            return String(localized: "Completed · \(SegmentCount.label(segmentCount))")
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
struct JobCancelAction: Equatable {
    enum Scope: Equatable {
        case wholeBatch
        case oneJob
    }

    let scope: Scope
    /// A localization key, kept as a String so the action stays Sendable and the row's `==` can read it.
    let help: String
    let axID: String

    /// The Queue page's ✕, as `QueueRow` had it: one control for the whole run.
    static var wholeBatch: JobCancelAction {
        JobCancelAction(scope: .wholeBatch, help: "Cancel Batch", axID: "Row.Button.CancelBatch")
    }

    /// The Batch page's ✕, as `BatchJobRow` had it: a running file is cancelled, a waiting one is removed.
    static func oneJob(status: BatchJob.Status) -> JobCancelAction {
        JobCancelAction(
            scope: .oneJob,
            help: status == .transcribing ? "Cancel" : "Remove",
            axID: "Row.Button.Cancel"
        )
    }

    @MainActor
    func run(for id: BatchJob.ID, in model: AppModel) {
        switch scope {
        case .wholeBatch: model.cancelAllInFlightBatchJobs()
        case .oneJob: model.cancelBatchJob(id)
        }
    }
}

/// The one row a batch job draws on every page; Equatable on what it draws, so a re-render skips unchanged jobs.
struct JobRow: View, Equatable {
    let id: BatchJob.ID
    let url: URL
    let status: BatchJob.Status
    let error: String?
    let segmentCount: Int
    let isSelected: Bool
    /// The sidebar's column is narrow: no progress bar and no trailing action, the status text alone.
    let compact: Bool
    let cancel: JobCancelAction?

    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    init(job: BatchJob, isSelected: Bool = false, compact: Bool = false, cancel: JobCancelAction? = nil) {
        self.id = job.id
        self.url = job.url
        self.status = job.status
        self.error = job.error
        self.segmentCount = job.segmentCount ?? job.transcript?.segments.count ?? 0
        self.isSelected = isSelected
        self.compact = compact
        self.cancel = cancel
    }

    nonisolated static func == (lhs: JobRow, rhs: JobRow) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.status == rhs.status && lhs.error == rhs.error
            && lhs.segmentCount == rhs.segmentCount && lhs.isSelected == rhs.isSelected
            && lhs.compact == rhs.compact && lhs.cancel == rhs.cancel
    }

    /// Only the sidebar's selection is a solid accent fill; the pages wash theirs, where onAccent would vanish.
    private var onAccent: Bool { isSelected && compact }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            EntryBadge(kind: EntrySourceKind(url: url), onAccent: onAccent)
            VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                Text(url.lastPathComponent)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(onAccent ? DS.Color.onAccent : DS.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine
                if !compact, BatchJobStatus.showsProgress(status) {
                    JobProgressBar(progress: model.batchProgress.box(for: id))
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
        .rowChrome(selected: isSelected, hovered: isHovering, selection: selection)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private var statusLine: some View {
        HStack(spacing: DS.Spacing.tight) {
            if let symbol = BatchJobStatus.symbol(for: status) {
                Image(systemName: symbol)
                    .font(DS.Font.secondary)
            }
            JobStatusText(
                status: status,
                error: error,
                segmentCount: segmentCount,
                progress: model.batchProgress.box(for: id)
            )
        }
        .foregroundStyle(onAccent ? DS.Color.onAccent : BatchJobStatus.tint(for: status))
    }

    @ViewBuilder
    private var action: some View {
        switch status {
        case .pending, .transcribing:
            if let cancel {
                actionButton(LocalizedStringKey(cancel.help), systemImage: "xmark", axID: cancel.axID) {
                    cancel.run(for: id, in: model)
                }
            }
        case .failed, .cancelled:
            actionButton("Retry", systemImage: "arrow.clockwise", axID: "Row.Button.Retry") {
                model.retryBatchJob(id)
            }
        case .done:
            actionButton("Open", systemImage: "doc.text", axID: "Row.Button.Open") {
                model.openBatchJobTranscript(id)
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

    private var selection: RowSelectionStyle {
        compact
            ? .native
            : .wash(fill: DS.Color.selectionWash, border: DS.Color.accent.opacity(0.35))
    }
}

/// The only views that read a job's progress, so a tick re-renders them and not the row around them.
private struct JobStatusText: View {
    let status: BatchJob.Status
    let error: String?
    let segmentCount: Int
    let progress: BatchJobProgress

    var body: some View {
        Text(BatchJobStatus.text(
            status: status,
            progress: status == .transcribing ? progress.fraction : 0,
            error: error,
            segmentCount: segmentCount
        ))
        .font(DS.Font.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

private struct JobProgressBar: View {
    let progress: BatchJobProgress

    var body: some View {
        DSProgressBar(value: progress.fraction > 0 ? progress.fraction : nil)
    }
}
