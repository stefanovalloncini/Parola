import SwiftUI
import UniformTypeIdentifiers
import ParolaCore

struct BatchJobList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.batchJobs.count) file\(model.batchJobs.count == 1 ? "" : "s")")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer()
                Button("Clear") { model.clearBatch() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(model.batchJobs.allSatisfy { $0.status == .transcribing })
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.top, DS.Spacing.regular)
            .padding(.bottom, DS.Spacing.small)

            ScrollView {
                LazyVStack(spacing: DS.Spacing.small) {
                    ForEach(model.batchJobs) { job in
                        BatchJobRow(job: job)
                            .onTapGesture { model.selectBatchJob(job.id) }
                    }
                }
                .padding(.horizontal, DS.Spacing.large)
                .padding(.bottom, DS.Spacing.large)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button {
                    model.presentBatchOpenPanel()
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.bottom, DS.Spacing.regular)
        }
    }
}

enum BatchMediaKind {
    case audio
    case video

    init(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            self = .audio
            return
        }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            self = .video
        } else {
            self = .audio
        }
    }
}

struct BatchJobRow: View {
    @EnvironmentObject var model: AppModel
    let job: BatchJob

    private var kind: BatchMediaKind { BatchMediaKind(url: job.url) }

    private var iconBackground: Color {
        switch kind {
        case .video: return Color(red: 0.30, green: 0.62, blue: 0.42)
        case .audio: return Color(red: 0.24, green: 0.62, blue: 0.66)
        }
    }

    private var iconSymbol: String {
        switch kind {
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        }
    }

    private var statusText: String {
        switch job.status {
        case .pending: return "Queued"
        case .transcribing:
            return job.progress > 0
                ? "Transcribing \(Int(job.progress * 100))%"
                : "Transcribing…"
        case .done: return "Complete"
        case .failed: return job.error ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .pending: return DS.Color.secondaryText
        case .transcribing: return DS.Color.accent
        case .done: return Color(red: 0.36, green: 0.66, blue: 0.46)
        case .failed: return DS.Color.danger
        case .cancelled: return DS.Color.secondaryText
        }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            iconSquare
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
            Spacer(minLength: DS.Spacing.small)
            cancelButton
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.regular)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                        .strokeBorder(
                            model.selectedBatchJobID == job.id ? DS.Color.accent.opacity(0.5) : DS.Color.separator.opacity(0.4),
                            lineWidth: model.selectedBatchJobID == job.id ? 1.5 : 0.5
                        )
                )
        }
        .contentShape(Rectangle())
    }

    private var iconSquare: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(iconBackground)
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: iconSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
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

    private var cancelButton: some View {
        Button {
            model.cancelBatchJob(job.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(DS.Color.separator.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .help(job.status == .transcribing ? "Cancel" : "Remove")
    }
}
