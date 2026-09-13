import SwiftUI
import ParolaCore

struct QueueRow: View {
    let job: BatchJob
    let isFocused: Bool
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            iconSquare
            VStack(alignment: .leading, spacing: 2) {
                Text(job.url.lastPathComponent)
                    .font(DS.Font.bodyStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusLine)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsProgressBar {
                    DSProgressBar(value: job.progress)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailingActions
                .opacity(hovered ? 1 : 0.55)
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular)
                .fill(isFocused ? DS.Color.accent.opacity(0.12) : DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular)
                .strokeBorder(DS.Color.accent.opacity(isFocused ? 0.7 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
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
            let exports = model.batchExportFormats
                .map { job.url.deletingPathExtension().appendingPathExtension($0.fileExtension) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            let primary = exports.first ?? job.url
            return NSItemProvider(object: primary as NSURL)
        }
    }

    private var iconSquare: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.small)
                .fill(iconTint.opacity(0.22))
            Image(systemName: iconName)
                .font(DS.Font.title3Medium)
                .foregroundStyle(iconTint)
        }
        .frame(width: 32, height: 32)
    }

    private var kind: BatchMediaKind { BatchMediaKind(url: job.url) }

    private var iconTint: Color { DS.mediaTint(for: kind) }

    private var iconName: String { kind.symbolName }

    private var showsProgressBar: Bool {
        switch job.status {
        case .pending, .transcribing: return true
        default: return false
        }
    }

    private var statusLine: String {
        switch job.status {
        case .pending:
            return "Queued"
        case .transcribing:
            guard job.progress >= 0.005 else { return "Transcribing…" }
            return "Transcribing… \(AppFormat.percent(job.progress))"
        case .cancelled:
            let fraction = AppFormat.percent(job.progress, fractionDigits: 1)
            return "Progress: \(fraction) – Cancelled"
        case .failed:
            return "Failed: \(job.error ?? "unknown reason")"
        case .done:
            let segments = job.transcript?.segments.count ?? 0
            return "Completed · \(SegmentCount.label(segments))"
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        switch job.status {
        case .pending, .transcribing:
            actionButton("Cancel Batch", systemImage: "xmark.circle.fill") {
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
                .font(DS.Font.title3Regular)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .axLeaf("Row.Button.\(help.replacingOccurrences(of: " ", with: ""))")
    }
}
