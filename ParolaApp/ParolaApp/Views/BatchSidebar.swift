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
                    JobRow(job: job, compact: true).tag(BatchJob.ID?.some(job.id))
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
