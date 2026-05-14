import SwiftUI
import ParolaCore

struct BatchSidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Batch — \(model.batchJobs.count) files")
                    .font(.headline)
                Spacer()
                Button { model.clearBatch() } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Clear batch")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(selection: Binding(
                get: { model.selectedBatchJobID },
                set: { id in if let id { model.selectBatchJob(id) } }
            )) {
                ForEach(model.batchJobs) { job in
                    BatchRow(job: job).tag(job.id)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct BatchRow: View {
    let job: BatchJob

    var body: some View {
        HStack(spacing: 10) {
            statusGlyph
            VStack(alignment: .leading, spacing: 2) {
                Text(job.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch job.status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .transcribing:
            ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var subtitle: String {
        switch job.status {
        case .pending: return "Pending"
        case .transcribing: return "Transcribing…"
        case .done:
            let count = job.transcript?.segments.count ?? 0
            return "\(count) segments"
        case .failed: return job.error ?? "Failed"
        }
    }
}
