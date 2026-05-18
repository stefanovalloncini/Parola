import SwiftUI
import ParolaCore

struct SegmentsScroll: View {
    @EnvironmentObject var model: AppModel
    @State private var speakerFilter: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.small) {
                    if let t = model.transcript {
                        let speakers = t.uniqueSpeakers
                        if speakers.count >= 2 {
                            SpeakerFilterRow(speakers: speakers, selection: $speakerFilter)
                                .padding(.bottom, DS.Spacing.tight)
                        }
                        ForEach(visibleSegments(in: t)) { seg in
                            SegmentCard(segment: seg, isCurrent: seg.id == model.currentSegmentID)
                                .id(seg.id)
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.large)
                .padding(.vertical, DS.Spacing.regular)
            }
            .onChange(of: model.currentSegmentID) { _, id in
                guard let id, model.player?.timeControlStatus == .playing else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: speakerFilter) { _, newValue in
                if newValue != nil, model.findIsOpen { model.toggleFind() }
            }
            .onChange(of: model.findIsOpen) { _, isOpen in
                if isOpen { speakerFilter = nil }
            }
            .onChange(of: model.transcript?.uniqueSpeakers ?? []) { _, speakers in
                if let current = speakerFilter, !speakers.contains(current) {
                    speakerFilter = nil
                }
            }
        }
    }

    private func visibleSegments(in transcript: Transcript) -> [TranscriptSegment] {
        guard let speakerFilter else { return transcript.segments }
        return transcript.segments.filter { $0.speaker == speakerFilter }
    }
}

private struct SpeakerFilterRow: View {
    let speakers: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.small) {
                SpeakerChip(label: "All", tint: nil, isSelected: selection == nil) {
                    selection = nil
                }
                ForEach(speakers, id: \.self) { speaker in
                    SpeakerChip(
                        label: speaker,
                        tint: DS.speakerColor(for: speaker),
                        isSelected: selection == speaker
                    ) {
                        selection = (selection == speaker) ? nil : speaker
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct SpeakerChip: View {
    let label: String
    let tint: Color?
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                }
                Text(label)
                    .font(DS.Font.caption)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DS.Color.separator.opacity(isSelected ? 0 : 0.5), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isSelected ? "Show all speakers" : "Show only \(label)")
    }

    private var background: Color {
        if isSelected { return DS.Color.accent }
        if hovering { return DS.Color.surfaceElevated.opacity(0.85) }
        return DS.Color.surfaceElevated
    }
}

struct SegmentCard: View {
    let segment: TranscriptSegment
    let isCurrent: Bool

    @EnvironmentObject var model: AppModel
    @State private var hovering: Bool = false
    @State private var isEditing: Bool = false
    @State private var draftText: String = ""
    @State private var renamingSpeaker: Bool = false
    @State private var draftSpeakerName: String = ""
    @State private var editingNote: Bool = false
    @State private var draftNote: String = ""
    @FocusState private var editingFocus: Bool

    private let radius: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, hovering && !isEditing ? 88 : 0)

            HStack(spacing: DS.Spacing.small) {
                Text(timestamp(segment.start))
                    .font(DS.Font.captionMono)
                    .foregroundStyle(isCurrent ? DS.Color.accent : DS.Color.secondaryText)
                if let speaker = segment.speaker {
                    Text(speaker)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.speakerColor(for: speaker))
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
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .contentShape(Rectangle())
        .draggable(draggablePayload)
        .onHover { hover in
            withAnimation(.easeOut(duration: 0.12)) { hovering = hover }
        }
        .onTapGesture {
            if !isEditing { model.seek(to: segment) }
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
                .font(.system(size: 10))
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
            Text(segment.text)
                .font(DS.Font.transcript)
                .textSelection(.enabled)
        }
    }

    @State private var timingPopoverOpen = false

    private var actionStrip: some View {
        HStack(spacing: 2) {
            cardButton(systemName: "pencil", help: "Edit") { beginEditing() }
            cardButton(systemName: "note.text", help: "Add note") { beginEditingNote() }
            cardButton(systemName: "play.fill", help: "Play from here") {
                model.seek(to: segment)
            }
            cardButton(systemName: "clock", help: "Nudge timing") {
                timingPopoverOpen = true
            }
            .popover(isPresented: $timingPopoverOpen, arrowEdge: .top) {
                SegmentTimingPopover(segment: segment)
                    .environmentObject(model)
            }
            cardButton(systemName: "doc.on.doc", help: "Copy segment") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
            }
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
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
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
                piece.foregroundColor = .accentColor
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
            attr[attrLo..<attrHi].backgroundColor = isCurrent ? Color.accentColor : Color.yellow
            attr[attrLo..<attrHi].foregroundColor = Color.black
        }
        return Text(attr)
    }

    private func karaoke(words: [WordTiming]) -> Text {
        var attr = AttributedString()
        let activeID = model.currentWordID
        for word in words {
            var piece = AttributedString(word.word + " ")
            if word.id == activeID {
                piece.foregroundColor = .accentColor
                piece.font = .body.bold()
            }
            attr.append(piece)
        }
        return Text(attr)
    }

    private var draggablePayload: String {
        let stamp = timestamp(segment.start)
        let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let speaker = segment.speaker, !speaker.isEmpty {
            return "\(stamp)  \(speaker): \(body)"
        }
        return "\(stamp)  \(body)"
    }

    private func timestamp(_ s: Double) -> String {
        Duration.seconds(s).formatted(
            .time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }
}
