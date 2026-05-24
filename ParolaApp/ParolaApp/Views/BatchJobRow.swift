import SwiftUI
import UniformTypeIdentifiers
import ParolaCore

struct BatchJobRow: View {
    @Environment(AppModel.self) private var model
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

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            iconSquare
            BatchJobDetail(job: job)
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
        .axLeaf("Row.Button.Cancel")
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
