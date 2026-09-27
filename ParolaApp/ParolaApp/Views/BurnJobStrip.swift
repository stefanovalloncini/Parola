import AppKit
import SwiftUI

/// The burn running in the background, or how the last one ended, along the bottom of whatever the window shows.
struct BurnJobStrip: View {
    @Environment(AppModel.self) private var model
    let job: BurnJob

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            Image(systemName: symbol)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(tint)
            message
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)
            if let progress = job.progress {
                DSProgressBar(value: progress)
                    .frame(width: 140)
                Text(AppFormat.percent(progress))
                    .font(DS.Font.secondary)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.secondaryText)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: DS.Spacing.small)
            actions
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(DS.Color.surfaceElevated)
        .overlay(alignment: .top) { Divider() }
        .axBranch("BurnStrip")
    }

    private var message: Text {
        let name = job.output.lastPathComponent
        switch job.state {
        case .running: return Text("Burning subtitles into \(name)")
        case .finished: return Text("Subtitles burned into \(name)")
        case .failed(let reason): return Text(verbatim: reason)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch job.state {
        case .running:
            Button("Cancel") { model.cancelBurn() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("BurnStrip.Button.Cancel")
        case .finished:
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([job.output]) }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("BurnStrip.Button.Reveal")
            dismissButton
        case .failed:
            dismissButton
        }
    }

    private var dismissButton: some View {
        Button {
            model.dismissBurnJob()
        } label: {
            Image(systemName: "xmark")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .buttonStyle(GlyphButtonStyle(side: 20))
        .help("Dismiss")
        .axLeaf("BurnStrip.Button.Dismiss")
    }

    private var symbol: String {
        switch job.state {
        case .running: return "film"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch job.state {
        case .running: return DS.Color.accentText
        case .finished: return DS.Palette.success
        case .failed: return DS.Color.danger
        }
    }
}
