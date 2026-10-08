import SwiftUI
import ParolaCore

/// One opening of the note editor. Each opening has its own id, so the sheet starts from the note as it is now.
struct SegmentNoteTarget: Identifiable {
    let id = UUID()
    let entryID: LibraryEntry.ID
    let segment: TranscriptSegment
    let note: String?
}

struct SegmentNoteSheet: View {
    let target: SegmentNoteTarget

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @FocusState private var fieldFocused: Bool

    init(target: SegmentNoteTarget) {
        self.target = target
        _draft = State(initialValue: target.note ?? "")
    }

    var body: some View {
        SheetFrame(title: "Segment note", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                TextField("Note", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(4...10)
                    .writingToolsBehavior(.complete)
                    .focused($fieldFocused)
                    .fieldChrome(focused: fieldFocused)
                    .onSubmit(save)
                    .axLeaf("TextField.Note")
            }
            .padding(DS.Spacing.regular)
        } footer: {
            footer
        }
        .sheetDescription(Text(verbatim: "\(Timecode.format(target.segment.start))  \(SegmentCard.displayText(target.segment.text))"))
        .sheetSize(width: 440)
        .footerHasCancel()
        .onAppear { fieldFocused = true }
        .axBranch("SegmentNote")
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.small) {
            if target.note != nil {
                Button(role: .destructive, action: delete) {
                    Text("Delete")
                        .foregroundStyle(DS.Color.dangerText)
                }
                .sheetSecondaryAction()
                .axLeaf("Button.Delete")
            }
            Spacer(minLength: DS.Spacing.small)
            Button("Cancel") { dismiss() }
                .sheetSecondaryAction()
                .keyboardShortcut(.cancelAction)
                .axLeaf("Button.Cancel")
            Button("Save", action: save)
                .sheetPrimaryAction()
                .keyboardShortcut(.defaultAction)
                .axLeaf("Button.Save")
        }
    }

    private func save() {
        write(draft)
    }

    private func delete() {
        write(nil)
    }

    private func write(_ note: String?) {
        if Self.canWrite(target, entryID: model.selectedEntryID, segments: model.transcript?.segments ?? []) {
            model.setSegmentNote(note, segmentID: target.segment.id)
        }
        dismiss()
    }

    /// A split, merge or delete made while the sheet was up can take its segment away; the note then goes nowhere.
    static func canWrite(_ target: SegmentNoteTarget, entryID: LibraryEntry.ID?, segments: [TranscriptSegment]) -> Bool {
        entryID == target.entryID && segments.contains { $0.id == target.segment.id }
    }
}
