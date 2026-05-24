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
            trailingActions
                .opacity(hovered ? 1 : 0.55)
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular)
                .fill(DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular)
                .stroke(DS.Color.accent.opacity(isFocused ? 0.55 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            switch job.status {
            case .pending, .transcribing:
                Button("Cancel batch") { model.cancelAllInFlightBatchJobs() }
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconTint)
        }
        .frame(width: 32, height: 32)
    }

    private var kind: BatchMediaKind { BatchMediaKind(url: job.url) }

    private var iconTint: Color {
        kind == .video ? .green : .teal
    }

    private var iconName: String {
        kind == .video ? "film" : "waveform"
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
        .axLeaf("Row.Button.\(help.replacingOccurrences(of: " ", with: ""))")
    }
}
