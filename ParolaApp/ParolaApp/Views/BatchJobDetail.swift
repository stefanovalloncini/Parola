import SwiftUI
import ParolaCore

struct BatchJobDetail: View {
    let job: BatchJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.url.lastPathComponent)
                .font(DS.Font.body.weight(.medium))
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            progressBar
            Text(statusText)
                .font(DS.Font.caption)
                .foregroundStyle(statusColor)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        switch job.status {
        case .pending:
            EmptyView()
        case .transcribing:
            if job.progress > 0 {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .frame(height: 3)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .frame(height: 3)
            }
        case .done:
            ProgressView(value: 1)
                .progressViewStyle(.linear)
                .tint(statusColor)
                .frame(height: 3)
        case .failed:
            ProgressView(value: 1)
                .progressViewStyle(.linear)
                .tint(DS.Color.danger)
                .frame(height: 3)
        case .cancelled:
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .tint(DS.Color.secondaryText)
                .frame(height: 3)
        }
    }

    private var statusText: String {
        switch job.status {
        case .pending: return String(localized: "Queued")
        case .transcribing:
            if job.progress > 0 {
                return String(localized: "Transcribing \(Int(job.progress * 100))%")
            }
            return String(localized: "Transcribing…")
        case .done: return String(localized: "Complete")
        case .failed: return job.error ?? String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .pending: return DS.Color.secondaryText
        case .transcribing: return DS.Color.accent
        case .done: return DS.Palette.success
        case .failed: return DS.Color.danger
        case .cancelled: return DS.Color.secondaryText
        }
    }
}
