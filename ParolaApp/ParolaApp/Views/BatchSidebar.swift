import SwiftUI
import ParolaCore

struct BatchSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Batch — \(model.batchJobs.count) files")
                    .font(DS.Font.heading)
                Spacer()
                Button { model.clearBatch() } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Clear batch")
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.regular)

            Divider()

            List(selection: $model.selectedBatchJobID) {
                ForEach(model.batchJobs) { job in
                    BatchRow(job: job).tag(BatchJob.ID?.some(job.id))
                }
            }
            .listStyle(.sidebar)
            .tint(DS.Color.accent)
            .onChange(of: model.selectedBatchJobID) { _, newValue in
                if let id = newValue { model.selectBatchJob(id) }
            }
        }
    }
}

private struct BatchRow: View {
    let job: BatchJob

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            statusGlyph
                .frame(width: 18)
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                Text(job.url.lastPathComponent)
                    .font(DS.Font.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer()
        }
        .padding(.vertical, DS.Spacing.tight)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch job.status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(DS.Color.secondaryText)
        case .transcribing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark")
                .foregroundStyle(DS.Color.accent)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(DS.Color.danger)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(DS.Color.secondaryText)
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
        case .cancelled: return "Cancelled"
        }
    }
}
