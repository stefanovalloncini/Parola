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
            HStack(spacing: 4) {
                if let statusSymbol {
                    Image(systemName: statusSymbol)
                        .font(DS.Font.caption)
                }
                Text(statusText)
                    .font(DS.Font.caption)
            }
            .foregroundStyle(statusColor)
        }
    }

    // Every state keeps the bar's 3 pt so a queue of mixed states is a column of one row height.
    @ViewBuilder
    private var progressBar: some View {
        switch job.status {
        case .pending:
            Color.clear.frame(height: 3)
        case .transcribing:
            if job.progress > 0 {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .tint(statusFill)
                    .frame(height: 3)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(statusFill)
                    .frame(height: 3)
            }
        case .done:
            Color.clear.frame(height: 3)
        case .failed:
            ProgressView(value: 1)
                .progressViewStyle(.linear)
                .tint(statusFill)
                .frame(height: 3)
        case .cancelled:
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .tint(statusFill)
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

    private var statusSymbol: String? {
        job.status == .done ? "checkmark.circle.fill" : nil
    }

    /// For the label. A fill answers a different question — see `statusFill`.
    private var statusColor: Color {
        switch job.status {
        case .pending: return DS.Color.secondaryText
        case .transcribing: return DS.Color.accentText
        case .done: return DS.Color.successText
        case .failed: return DS.Color.dangerText
        case .cancelled: return DS.Color.secondaryText
        }
    }

    // Only the statuses that draw a bar reach this; .pending and .done draw a spacer instead.
    private var statusFill: Color {
        switch job.status {
        case .transcribing: return DS.Color.accent
        case .failed: return DS.Color.danger
        default: return DS.Color.secondaryText
        }
    }
}
