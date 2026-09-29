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
            Image(systemName: notice.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(DS.Font.bodyStrong)
                .foregroundStyle(notice.succeeded ? DS.Palette.success : DS.Color.danger)
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
            Button {
                model.dismissExportNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .buttonStyle(GlyphButtonStyle(side: 20))
            .help("Dismiss")
            .axLeaf("ExportNotice.Button.Dismiss")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(DS.Color.surfaceElevated)
        .overlay(alignment: .top) { Divider() }
        .task(id: notice.id) {
            guard notice.succeeded else { return }
            try? await Task.sleep(for: Self.dismissAfter)
            guard !Task.isCancelled, model.exportNotice?.id == notice.id else { return }
            model.dismissExportNotice()
        }
        .axBranch("ExportNotice")
    }
}
