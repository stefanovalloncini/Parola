import SwiftUI
import ParolaCore

struct SegmentCard: View {
    let segment: TranscriptSegment
    var hoveredSpeaker: Binding<String?> = .constant(nil)
    var confidenceBucket: SegmentConfidence.Bucket? = nil
    var qcIssues: [SubtitleQC.Issue] = []

    @Environment(AppModel.self) private var model
    @State private var hovering: Bool = false
    @State private var isEditing: Bool = false
    @State private var draftText: String = ""
    @State private var renamingSpeaker: Bool = false
    @State private var draftSpeakerName: String = ""
    @State private var assigningSpeaker: Bool = false
    @State private var draftAssignSpeakerName: String = ""
    @State private var editingNote: Bool = false
    @State private var draftNote: String = ""
    @FocusState private var editingFocus: Bool

    private let radius: CGFloat = DS.Radius.regular

    /// Read here rather than passed in: the scroll's ForEach would otherwise re-walk every segment on each playback tick.
    private var isCurrent: Bool { model.currentSegmentID == segment.id }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DS.Spacing.small) {
                Button {
                    if model.player != nil { model.seek(to: segment) }
                } label: {
                    Text(Timecode.format(segment.start))
                        .font(model.monospacedTimestamps ? DS.Font.captionMono : DS.Font.caption)
                        .foregroundStyle(isCurrent ? DS.Color.highlight : DS.Color.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Play from here")
                .axLeaf("Card.Button.SeekTimestamp")
                // A speakerless segment renders no chip, so the timestamp carries the assign menu too.
                .contextMenu { assignSpeakerMenu }
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
                            assignSpeakerMenu
                        }
                }
                if !qcIssues.isEmpty {
                    Image(systemName: "exclamationmark.triangle")
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .help(Self.qcHelpText(qcIssues))
                        .accessibilityLabel("Subtitle warnings")
                        .axLeaf("Card.Badge.SubtitleQC")
                }
            }
            if let note = model.currentSegmentNote(for: segment.id), !note.isEmpty {
                noteRow(text: note)
            }
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.regular)
        .background(cardBackground)
        .overlay(alignment: .bottomTrailing) {
            if hovering && !isEditing {
                actionStrip
                    .padding(.bottom, 6)
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
        // simultaneousGesture: .textSelection consumes plain taps, so a card-level .onTapGesture never fires on text.
        // Skipped while word karaoke shows: its per-word links own the click, and a simultaneous segment seek would race the word seek.
        .simultaneousGesture(TapGesture().onEnded {
            if !isEditing, !showsWordKaraoke, model.player != nil { model.seek(to: segment) }
        })
        .alert("Rename speaker", isPresented: $renamingSpeaker, presenting: segment.speaker) { current in
            TextField("Name", text: $draftSpeakerName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = draftSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != current else { return }
                model.applySpeakerRenames([current: trimmed])
            }
        }
        .alert("Assign speaker", isPresented: $assigningSpeaker) {
            TextField("Name", text: $draftAssignSpeakerName)
            Button("Cancel", role: .cancel) {}
            Button("Assign") {
                let trimmed = draftAssignSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                model.assignSpeaker(trimmed, toSegmentID: segment.id)
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
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Color.accent.opacity(0.08))
        )
    }

    private var cardBackground: Color {
        isCurrent ? DS.Color.highlight.opacity(0.10) : DS.Color.surfaceElevated
    }

    private func confidenceColor(_ bucket: SegmentConfidence.Bucket) -> Color {
        DS.confidenceColor(for: bucket).opacity(0.7)
    }

    private var borderColor: Color {
        if isCurrent { return DS.Color.highlight.opacity(0.55) }
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
        } else if showsWordKaraoke, let words = segment.words {
            karaoke(words: words)
                .font(DS.Font.transcript)
                .textSelection(.enabled)
                .tint(.primary)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "parola-seek-time",
                          let seconds = url.host(percentEncoded: false).flatMap(Double.init) else {
                        return .systemAction
                    }
                    model.seekTo(seconds: seconds)
                    return .handled
                })
        } else if isCurrent, model.karaokeHighlight, model.player != nil {
            SyntheticKaraoke(segment: segment)
                .font(DS.Font.transcript)
                .textSelection(.enabled)
        } else {
            Text(Self.displayText(segment.text))
                .font(DS.Font.transcript)
                .textSelection(.enabled)
        }
    }

    private var showsWordKaraoke: Bool {
        !isEditing
            && !(model.findIsOpen && !model.findQuery.isEmpty)
            && isCurrent
            && model.karaokeHighlight
            && segment.words?.isEmpty == false
    }

    static func displayText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func qcHelpText(_ issues: [SubtitleQC.Issue]) -> String {
        issues.map { issue in
            switch issue {
            case .lineTooLong(let limit):
                return "Line longer than \(limit) characters"
            case .tooFast(let charactersPerSecond):
                return "\(charactersPerSecond) characters per second"
            case .tooShort:
                return "Shorter than \(SubtitleQC.minimumDuration) seconds"
            }
        }.joined(separator: "\n")
    }

    nonisolated static func speakerLabel(for speaker: String?) -> String? {
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
            cardButton(systemName: "doc.on.doc", help: "Copy segment with timestamp") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draggablePayload, forType: .string)
            }
            .axLeaf("Card.Button.Copy")
            moreMenu
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular)
                .fill(DS.Color.surface)
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
        )
    }

    private var moreMenu: some View {
        Menu {
            Button("Nudge timing…") { timingPopoverOpen = true }
                .axLeaf("Card.Button.Timing")
            Button("Split segment") { splitSegment() }
                .axLeaf("Card.Button.Split")
            Button("Merge with next segment") { model.mergeSegmentWithNext(id: segment.id) }
                .disabled(isLastSegment)
                .axLeaf("Card.Button.Merge")
            Button("Copy link to this segment") { copyDeeplink() }
                .axLeaf("Card.Button.CopyLink")
            Divider()
            Button("Delete segment", role: .destructive) { model.deleteSegment(id: segment.id) }
                .axLeaf("Card.Button.Delete")
        } label: {
            Image(systemName: "ellipsis")
                .font(DS.Font.subheadlineEmphasized)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("More actions")
        .accessibilityLabel("More actions")
        .axLeaf("Card.Menu.More")
        .popover(isPresented: $timingPopoverOpen, arrowEdge: .top) {
            SegmentTimingPopover(segment: segment)
                .environment(model)
        }
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

    private var isLastSegment: Bool {
        model.transcript?.segments.last?.id == segment.id
    }

    private var assignSpeakerMenu: some View {
        Menu("Assign Speaker") {
            ForEach(model.transcriptSpeakers, id: \.self) { name in
                Button {
                    model.assignSpeaker(name, toSegmentID: segment.id)
                } label: {
                    if name == segment.speaker {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            if !model.transcriptSpeakers.isEmpty { Divider() }
            Button("New Speaker…") {
                draftAssignSpeakerName = ""
                assigningSpeaker = true
            }
            if segment.speaker != nil {
                Button("No Speaker") {
                    model.assignSpeaker(nil, toSegmentID: segment.id)
                }
            }
        }
    }

    private func splitSegment() {
        if isCurrent,
           let words = segment.words,
           let wordID = model.currentWordID,
           let index = words.firstIndex(where: { $0.id == wordID }) {
            model.splitSegment(id: segment.id, atWordIndex: index)
        } else {
            model.splitSegment(id: segment.id, atFraction: 0.5)
        }
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

    nonisolated static func syntheticKaraokeTokens(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    nonisolated static func syntheticKaraokeIndex(cumulativeChars: [Int], progress: Double) -> Int {
        guard let total = cumulativeChars.last, total > 0 else { return cumulativeChars.count - 1 }
        let target = Int((min(1.0, max(0, progress)) * Double(total)).rounded())
        return cumulativeChars.firstIndex { $0 >= target } ?? cumulativeChars.count - 1
    }

    static func syntheticKaraokeText(tokens: [String], spokenIndex: Int) -> AttributedString {
        var attr = AttributedString()
        for (index, token) in tokens.enumerated() {
            var piece = AttributedString(token + (index == tokens.count - 1 ? "" : " "))
            if index == spokenIndex {
                piece.foregroundColor = DS.Color.highlight
                piece.font = .body.bold()
            }
            attr.append(piece)
        }
        return attr
    }

    private var highlightedText: Text {
        // Only cards holding a match read currentMatchIndex, so stepping through matches leaves the rest alone.
        guard !model.matches.isEmpty else { return Text(segment.text) }
        let segmentMatches = model.match(in: segment.id)
        guard !segmentMatches.isEmpty else { return Text(segment.text) }
        var attr = AttributedString(segment.text)
        let text = segment.text
        let currentMatchID = model.currentMatch?.id
        for m in segmentMatches {
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
            // Explicit foreground on every linked run, or the link tint overrides it (7977ad5).
            piece.link = URL(string: "parola-seek-time://\(word.start)")
            piece.underlineStyle = nil
            piece.foregroundColor = DS.Color.primaryText
            if word.id == activeWordID {
                piece.foregroundColor = DS.Color.highlight
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

/// Owns the playback tick so the whole card doesn't re-render five times a second while a segment plays.
private struct SyntheticKaraoke: View {
    let segment: TranscriptSegment

    @Environment(AppModel.self) private var model
    private let tokens: [String]
    private let cumulativeChars: [Int]

    init(segment: TranscriptSegment) {
        self.segment = segment
        let tokens = SegmentCard.syntheticKaraokeTokens(segment.text)
        self.tokens = tokens
        var running = 0
        cumulativeChars = tokens.map {
            running += $0.count
            return running
        }
    }

    var body: some View {
        if tokens.isEmpty {
            Text(segment.text)
        } else {
            SyntheticKaraokeLine(tokens: tokens, spokenIndex: spokenIndex)
                .equatable()
        }
    }

    private var spokenIndex: Int {
        let elapsed = max(0, model.currentTimeSeconds - segment.start)
        let span = max(0.001, segment.end - segment.start)
        return SegmentCard.syntheticKaraokeIndex(cumulativeChars: cumulativeChars, progress: elapsed / span)
    }
}

private struct SyntheticKaraokeLine: View, Equatable {
    let tokens: [String]
    let spokenIndex: Int

    var body: some View {
        Text(SegmentCard.syntheticKaraokeText(tokens: tokens, spokenIndex: spokenIndex))
    }
}
