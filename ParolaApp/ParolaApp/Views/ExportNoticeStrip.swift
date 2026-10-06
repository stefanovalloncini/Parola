import AppKit
import SwiftUI

/// A clean bulk export's count goes away on its own; anything that failed waits to be dismissed.
struct ExportNoticeStrip: View {
    @Environment(AppModel.self) private var model
    let notice: ExportNotice

    static let dismissAfter: Duration = .seconds(6)
    static let listedFailures = 3

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            Image(systemName: Self.iconName(for: notice.tone))
                .font(DS.Font.bodyStrong)
                .foregroundStyle(iconColor)
                .accessibilityLabel("Error")
                .accessibilityHidden(!Self.iconIsSpoken(notice.tone))
            VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                Text(verbatim: notice.message)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.primaryText)
                ForEach(Array(notice.failures.prefix(Self.listedFailures).enumerated()), id: \.offset) { _, failure in
                    Text(verbatim: "\(failure.name): \(failure.reason)")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if notice.failures.count > Self.listedFailures {
                    Text("and \(notice.failures.count - Self.listedFailures) more")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
            Spacer(minLength: DS.Spacing.small)
            if notice.offersFolderChoice {
                Button("Choose Folder…") {
                    model.dismissExportNotice()
                    model.chooseAutoExportFolder()
                }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("ExportNotice.Button.ChooseFolder")
            }
            if let folder = notice.folder {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("ExportNotice.Button.Reveal")
            }
            ForEach(notice.actions) { action in
                Button(action.title) { model.performNoticeAction(action) }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("ExportNotice.Button.\(axName(for: action.handler))")
            }
            Button {
                model.dismissExportNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .buttonStyle(GlyphButtonStyle(side: 20))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
            .axLeaf("ExportNotice.Button.Dismiss")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(DS.Color.surfaceElevated)
        .overlay(alignment: .top) { Divider() }
        .task(id: notice.id) {
            guard notice.autoDismisses else { return }
            try? await Task.sleep(for: Self.dismissAfter)
            guard !Task.isCancelled, model.exportNotice?.id == notice.id else { return }
            model.dismissExportNotice()
        }
        .axBranch("ExportNotice")
    }

    /// Only a failure's sign adds to its message; the system reads the others as Info and Selected, which say nothing or mislead.
    nonisolated static func iconIsSpoken(_ tone: ExportNotice.Tone) -> Bool {
        tone == .failure
    }

    nonisolated static func iconName(for tone: ExportNotice.Tone) -> String {
        switch tone {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch notice.tone {
        case .success: DS.Palette.success
        case .info: DS.Color.secondaryText
        case .failure: DS.Color.danger
        }
    }

    private func axName(for handler: ExportNotice.Action.Handler) -> String {
        switch handler {
        case .openEntry: "Open"
        case .transcribeEntry: "Transcribe"
        case .retryTake, .retrySavedTake, .retryRun: "Retry"
        case .showTake, .showSavedTake: "Show"
        case .openRecentlyDeleted: "RecentlyDeleted"
        case .revealFile: "RevealInFinder"
        }
    }
}
