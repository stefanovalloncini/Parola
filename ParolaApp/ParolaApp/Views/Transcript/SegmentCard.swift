import SwiftUI
import ParolaCore

struct SegmentCard: View {
    let segment: TranscriptSegment
    let isCurrent: Bool
    var hoveredSpeaker: Binding<String?> = .constant(nil)
    var confidenceBucket: SegmentConfidence.Bucket? = nil

    @Environment(AppModel.self) private var model
    @State private var hovering: Bool = false
    @State private var isEditing: Bool = false
    @State private var draftText: String = ""
    @State private var renamingSpeaker: Bool = false
    @State private var draftSpeakerName: String = ""
    @State private var editingNote: Bool = false
    @State private var draftNote: String = ""
    @FocusState private var editingFocus: Bool

    private let radius: CGFloat = 12

    // Hover reserves room for the floating actionStrip (~200pt with every button) so it never covers the first text line.
    private let actionStripReserve: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, hovering && !isEditing ? actionStripReserve : 0)

            HStack(spacing: DS.Spacing.small) {
                Text(Timecode.format(segment.start))
                    .font(model.monospacedTimestamps ? DS.Font.captionMono : DS.Font.caption)
                    .foregroundStyle(isCurrent ? DS.Color.accent : DS.Color.secondaryText)
                if let rawSpeaker = segment.speaker, let speaker = Self.speakerLabel(for: rawSpeaker) {
                    Text(speaker)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.speakerColor(for: rawSpeaker))
                        .onHover { hovering in
                            hoveredSpeaker.wrappedValue = hovering ? rawSpeaker : nil
                        }
                        .contextMenu {
                            Button("Rename \(speaker)…") {
                                draftSpeakerName = speaker
                                renamingSpeaker = true
                            }
                        }
                }
            }
            if let note = model.currentSegmentNote(for: segment.id), !note.isEmpty {
                noteRow(text: note)
            }
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.regular)
        .background(cardBackground)
        .overlay(alignment: .topTrailing) {
            if hovering && !isEditing {
                actionStrip
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                    .transition(.opacity)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(borderColor, lineWidth: isCurrent ? 1.5 : 1)
        )
        .overlay(alignment: .leading) {
            if let bucket = confidenceBucket {
                Rectangle()
                    .fill(confidenceColor(bucket))
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .contentShape(Rectangle())
        .draggable(draggablePayload)
        .onHover { hover in
            withAnimation(.easeOut(duration: 0.12)) { hovering = hover }
        }
        .onTapGesture {
            if !isEditing, model.player != nil { model.seek(to: segment) }
        }
        .alert("Rename speaker", isPresented: $renamingSpeaker, presenting: segment.speaker) { current in
            TextField("Name", text: $draftSpeakerName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = draftSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != current else { return }
                model.applySpeakerRenames([current: trimmed])
            }
        }
        .alert("Segment note", isPresented: $editingNote) {
            TextField("Note", text: $draftNote)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                model.setSegmentNote(draftNote, segmentID: segment.id)
            }
            if model.currentSegmentNote(for: segment.id) != nil {
                Button("Delete", role: .destructive) {
                    model.setSegmentNote(nil, segmentID: segment.id)
                }
            }
        }
    }

    private func beginEditingNote() {
        draftNote = model.currentSegmentNote(for: segment.id) ?? ""
        editingNote = true
    }

    @ViewBuilder
    private func noteRow(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(DS.Font.caption2)
                .foregroundStyle(DS.Color.accent)
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.primaryText.opacity(0.85))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Color.accent.opacity(0.08))
        )
    }

    private var cardBackground: Color {
        isCurrent ? DS.Color.accent.opacity(0.10) : DS.Color.surfaceElevated
    }

    private func confidenceColor(_ bucket: SegmentConfidence.Bucket) -> Color {
        switch bucket {
        case .high:   return DS.Palette.success.opacity(0.7)
        case .medium: return DS.Palette.warning.opacity(0.7)
        case .low:    return Color.red.opacity(0.7)
        }
    }

    private var borderColor: Color {
        if isCurrent { return DS.Color.accent.opacity(0.55) }
        if hovering { return DS.Color.accent.opacity(0.25) }
        return DS.Color.separator.opacity(0.6)
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            TextField("Segment text", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Font.transcript)
                .lineLimit(1...20)
                .focused($editingFocus)
                .onChange(of: editingFocus) { _, focused in
                    if !focused { commitEdit() }
                }
                .onSubmit { commitEdit() }
        } else if model.findIsOpen, !model.findQuery.isEmpty {
            highlightedText
                .font(DS.Font.transcript)
                .textSelection(.enabled)
        } else if isCurrent, model.karaokeHighlight, let words = segment.words, !words.isEmpty {
            karaoke(words: words)
                .font(DS.Font.transcript)
                .textSelection(.enabled)
        } else if isCurrent, model.karaokeHighlight, model.player != nil {
            syntheticKaraoke
                .font(DS.Font.transcript)
                .textSelection(.enabled)
        } else {
            Text(Self.displayText(segment.text))
                .font(DS.Font.transcript)
                .textSelection(.enabled)
        }
    }

    static func displayText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func speakerLabel(for speaker: String?) -> String? {
        guard let speaker else { return nil }
        let flattened = speaker
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? nil : flattened
    }

    @State private var timingPopoverOpen = false

    private var actionStrip: some View {
        HStack(spacing: 4) {
            cardButton(systemName: "pencil", help: "Edit") { beginEditing() }
                .axLeaf("Card.Button.Edit")
            cardButton(systemName: "note.text", help: "Add note") { beginEditingNote() }
                .axLeaf("Card.Button.Note")
            if model.player != nil {
                cardButton(systemName: "play.fill", help: "Play from here") {
                    model.seek(to: segment)
                }
                .axLeaf("Card.Button.Play")
            }
            cardButton(systemName: "clock", help: "Nudge timing") {
                timingPopoverOpen = true
            }
            .popover(isPresented: $timingPopoverOpen, arrowEdge: .top) {
                SegmentTimingPopover(segment: segment)
                    .environment(model)
            }
            .axLeaf("Card.Button.Timing")
            cardButton(systemName: "doc.on.doc", help: "Copy segment with timestamp") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draggablePayload, forType: .string)
            }
            .axLeaf("Card.Button.Copy")
            cardButton(systemName: "link", help: "Copy parola:// link to this segment") {
                copyDeeplink()
            }
            .axLeaf("Card.Button.CopyLink")
            Divider().frame(height: 14).padding(.horizontal, 1)
            cardButton(systemName: "trash", help: "Delete segment") {
                model.deleteSegment(id: segment.id)
            }
            .axLeaf("Card.Button.Delete")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular)
                .fill(DS.Color.surface)
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
        )
    }

    private func cardButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Font.subheadlineEmphasized)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private func beginEditing() {
        draftText = segment.text
        isEditing = true
        Task { @MainActor in editingFocus = true }
    }

    private func commitEdit() {
        if draftText != segment.text {
            model.editSegment(id: segment.id, newText: draftText)
        }
        isEditing = false
    }

    private var syntheticKaraoke: Text {
        let tokens = segment.text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return Text(segment.text) }

        let elapsed = max(0, model.currentTimeSeconds - segment.start)
        let span = max(0.001, segment.end - segment.start)
        let progress = min(1.0, elapsed / span)
        let totalChars = tokens.reduce(0) { $0 + $1.count }
        let target = Int((progress * Double(totalChars)).rounded())

        var acc = 0
        var marked = false
        var attr = AttributedString()
        for (i, token) in tokens.enumerated() {
            acc += token.count
            var piece = AttributedString(token + (i == tokens.count - 1 ? "" : " "))
            if !marked && (acc >= target || i == tokens.count - 1) {
                piece.foregroundColor = DS.Color.accent
                piece.font = .body.bold()
                marked = true
            }
            attr.append(piece)
        }
        return Text(attr)
    }

    private var highlightedText: Text {
        var attr = AttributedString(segment.text)
        let text = segment.text
        let currentMatchID = model.currentMatch?.id
        for m in model.match(in: segment.id) {
            guard
                let stringLo = text.utf16.index(text.utf16.startIndex, offsetBy: m.range.lowerBound, limitedBy: text.utf16.endIndex),
                let stringHi = text.utf16.index(text.utf16.startIndex, offsetBy: m.range.upperBound, limitedBy: text.utf16.endIndex),
                let attrLo = AttributedString.Index(stringLo, within: attr),
                let attrHi = AttributedString.Index(stringHi, within: attr)
            else { continue }
            let isCurrent = m.id == currentMatchID
            attr[attrLo..<attrHi].backgroundColor = isCurrent ? DS.Color.accent : Color.yellow
            attr[attrLo..<attrHi].foregroundColor = Color.black
        }
        return Text(attr)
    }

    private func karaoke(words: [WordTiming]) -> Text {
        Text(Self.karaokeText(words: words, activeWordID: model.currentWordID))
    }

    static func karaokeText(words: [WordTiming], activeWordID: WordTiming.ID?) -> AttributedString {
        var attr = AttributedString()
        for (index, word) in words.enumerated() {
            if index > 0, word.word.first != "'", word.word.first != "\u{2019}" {
                attr.append(AttributedString(" "))
            }
            var piece = AttributedString(word.word)
            if word.id == activeWordID {
                piece.foregroundColor = DS.Color.accent
                piece.font = .body.bold()
            }
            attr.append(piece)
        }
        return attr
    }

    private func copyDeeplink() {
        guard let entryID = model.selectedEntryID else { return }
        var components = URLComponents()
        components.scheme = "parola"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "entry", value: entryID),
            URLQueryItem(name: "t", value: String(format: "%.2f", segment.start)),
        ]
        guard let url = components.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private var draggablePayload: String {
        let stamp = Timecode.format(segment.start)
        let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let speaker = Self.speakerLabel(for: segment.speaker) {
            return "\(stamp)  \(speaker): \(body)"
        }
        return "\(stamp)  \(body)"
    }
}
