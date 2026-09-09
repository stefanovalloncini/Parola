import SwiftUI
import ParolaCore

struct DuplicateImportSheet: View {
    @Environment(AppModel.self) private var model
    let pending: DuplicateImport

    var body: some View {
        SheetFrame(
            icon: "doc.on.doc",
            iconTint: DS.Color.accent,
            title: "Already in your library",
            onClose: { model.dismissDuplicateImport() },
            content: { contentBody },
            footer: { footerBody }
        )
        .sheetSize(width: 440, minHeight: 200, maxHeight: 320)
        .closeLeaf("Duplicate.Button.Close")
        .axBranch("Duplicate")
    }

    private var contentBody: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("\(pending.fileURL.lastPathComponent) matches a transcript you already have.")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .axLeaf("Duplicate.Text.Summary")

            VStack(alignment: .leading, spacing: DS.Spacing.snug) {
                Text(pending.entryTitle)
                    .font(DS.Font.heading)
                    .lineLimit(2)
                    .axLeaf("Duplicate.Text.Title")

                if let model = LibraryEntryDisplay.modelName(raw: pending.modelName) {
                    detail("Model", model)
                }
                detail("Added", AppFormat.dateAndTime(pending.createdAt))
                if let seconds = pending.durationSeconds, seconds > 0 {
                    detail("Length", Timecode.format(seconds))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.regular)
            .background(DS.Palette.subtleFill)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))

            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.regular)
    }

    private func detail(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(DS.Font.caption)
                .lineLimit(1)
        }
    }

    private var footerBody: some View {
        HStack(spacing: DS.Spacing.small) {
            Spacer(minLength: DS.Spacing.small)

            Button("Transcribe Again") { model.transcribeDuplicateAgain() }
                .sheetSecondaryAction()
                .axLeaf("Duplicate.Button.TranscribeAgain")

            Button("Open Existing") { model.openExistingDuplicate() }
                .sheetPrimaryAction()
                .keyboardShortcut(.defaultAction)
                .axLeaf("Duplicate.Button.OpenExisting")
        }
    }
}
