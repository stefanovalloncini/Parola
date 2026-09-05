import SwiftUI
import UniformTypeIdentifiers
import ParolaCore

struct BatchJobRow: View {
    @Environment(AppModel.self) private var model
    let job: BatchJob

    private var kind: BatchMediaKind { BatchMediaKind(url: job.url) }

    private var iconBackground: Color {
        DS.mediaTint(for: kind)
    }

    private var iconSymbol: String { kind.symbolName }

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
                .fill(isSelected ? DS.Color.accent.opacity(0.12) : DS.Color.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                        .strokeBorder(
                            isSelected ? DS.Color.accent.opacity(0.7) : DS.Color.separator.opacity(0.4),
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                )
        }
        .contentShape(Rectangle())
    }

    private var isSelected: Bool { model.selectedBatchJobID == job.id }

    private var iconSquare: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(iconBackground)
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: iconSymbol)
                    .font(DS.Font.bodyEmphasized)
                    .foregroundStyle(.white)
            }
    }

    private var cancelButton: some View {
        Button {
            model.cancelBatchJob(job.id)
        } label: {
            Image(systemName: "xmark")
                .font(DS.Font.subheadlineEmphasized)
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

    /// Intake's lists win: `UTType(filenameExtension: "mkv")` is dynamic and conforms to neither `.movie` nor `.video`.
    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        if FolderWatcher.videoExtensions.contains(ext) {
            self = .video
        } else if FolderWatcher.audioExtensions.contains(ext) {
            self = .audio
        } else if let type = UTType(filenameExtension: ext) {
            self = type.conforms(to: .movie) || type.conforms(to: .video) ? .video : .audio
        } else {
            self = .audio
        }
    }

    var symbolName: String {
        switch self {
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        }
    }
}
