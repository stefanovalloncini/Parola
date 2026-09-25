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
        SheetFrame(icon: "note.text", title: "Segment note", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text(verbatim: "\(Timecode.format(target.segment.start))  \(SegmentCard.displayText(target.segment.text))")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(2)
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
        .sheetSize(width: 440)
        .hidesCloseButton()
        .onAppear { fieldFocused = true }
        .axBranch("SegmentNote")
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.small) {
            if target.note != nil {
                Button(action: delete) {
                    Text("Delete")
                        .foregroundStyle(DS.Color.dangerText)
                }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("Button.Delete")
            }
            Spacer(minLength: DS.Spacing.small)
            Button("Cancel") { dismiss() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .keyboardShortcut(.cancelAction)
                .axLeaf("Button.Cancel")
            Button("Save", action: save)
                .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
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
        if model.selectedEntryID == target.entryID {
            model.setSegmentNote(note, segmentID: target.segment.id)
        }
        dismiss()
    }
}
