import SwiftUI
import ParolaCore

struct SegmentCard: View {
    let segment: TranscriptSegment
    var hoveredSpeaker: Binding<String?> = .constant(nil)
    var confidenceBucket: SegmentConfidence.Bucket? = nil
    var qcIssues: [SubtitleQC.Issue] = []
    let translation: String?
    let translationSideBySide: Bool

    @Environment(AppModel.self) private var model
    @State private var hovering: Bool = false
    @State private var inlineEdit = InlineEdit()
    @State private var draftText: String = ""
    @State private var renamingSpeaker: Bool = false
    @State private var draftSpeakerName: String = ""
    @State private var assigningSpeaker: Bool = false
    @State private var assigningPerson: Bool = false
    @State private var draftAssignSpeakerName: String = ""
    @State private var copied = false
    @State private var copiedReset: Task<Void, Never>?
    @FocusState private var editingFocus: Bool

    private let radius: CGFloat = DS.Radius.regular

    /// Read here rather than passed in: the scroll's ForEach would otherwise re-walk every segment on each playback tick.
    private var isCurrent: Bool { model.currentSegmentID == segment.id }
    private var isEditing: Bool { inlineEdit.isEditing }

    var body: some View {
        // Read once: the star shows in the meta cluster, the action strip and the ••• menu.
        let isFavorite = model.isSegmentFavorite(segment.id)
        return VStack(alignment: .leading, spacing: DS.Spacing.small) {
            if let speaker = labelledSpeaker {
                speakerLine(speaker: speaker, isFavorite: isFavorite)
                contentRow
            } else {
                // With no chip to carry, the meta cluster rides the text's first line rather than holding a row of its own.
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                    contentRow
                    metaCluster(isFavorite: isFavorite)
                }
            }

            if !qcIssues.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .help(Self.qcHelpText(qcIssues))
                    .accessibilityLabel("Subtitle warnings")
                    .axLeaf("Card.Badge.SubtitleQC")
            }
            if let note = model.currentSegmentNote(for: segment.id), !note.isEmpty {
                noteRow(text: note)
            }
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.regular)
        .background(cardBackground)
        .contentShape(Rectangle())
        // .textSelection consumes plain taps, so only a simultaneous tap also seeks from clicks on the text.
        .simultaneousGesture(TapGesture().onEnded(seekFromCard), including: showsWordKaraoke ? .subviews : .all)
        // Under word karaoke the text keeps its clicks for the word links, which a card seek would race; the rest replays.
        .gesture(TapGesture().onEnded(seekFromCard), including: showsWordKaraoke ? .all : .subviews)
        // Laid over the tap rather than under it, so a click on the strip runs its own button and never seeks.
        .overlay(alignment: .bottomTrailing) {
            if Self.showsActionStrip(hovering: hovering, timingPopoverOpen: timingPopoverOpen, isEditing: isEditing) {
                actionStrip(isFavorite: isFavorite)
                    .padding(.bottom, DS.Spacing.snug)
                    .padding(.trailing, DS.Spacing.snug)
                    .transition(.opacity)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(
                    Self.borderColor(isCurrent: isCurrent, hovering: hovering),
                    lineWidth: Self.borderWidth(isCurrent: isCurrent)
                )
                .allowsHitTesting(false)
        )
        .overlay(alignment: .leading) {
            if let bucket = confidenceBucket {
                Rectangle()
                    .fill(confidenceColor(bucket))
                    .frame(width: 3)
                    .padding(.vertical, DS.Spacing.tight)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .contentShape(Rectangle())
        .rowStateAnimation(hovering)
        .contextMenu { assignSegmentMenu }
        .draggable(draggablePayload)
        .onHover { hovering = $0 }
        .alert("Rename speaker", isPresented: $renamingSpeaker, presenting: segment.speaker) { current in
            TextField("Name", text: $draftSpeakerName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = draftSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                model.renameSpeakerLabel(current, to: trimmed)
            }
        }
        .alert("Assign speaker", isPresented: $assigningSpeaker) {
            TextField("Name", text: $draftAssignSpeakerName)
            Button("Cancel", role: .cancel) {}
            Button("Assign") {
                let trimmed = draftAssignSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await model.assignSegment(segment.id, toNewPersonNamed: trimmed) }
            }
        }
    }

    /// Two equal columns when a translation shows side by side, so the original keeps its width
    /// whatever the translation runs to.
    @ViewBuilder
    private var contentRow: some View {
        if let translation, !isEditing, translationSideBySide {
            HStack(alignment: .top, spacing: DS.Spacing.regular) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                translationText(translation)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let translation, !isEditing {
                    translationText(translation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func translationText(_ text: String) -> some View {
        Text(Self.displayText(text))
            .font(DS.Font.transcript)
            .lineSpacing(DS.Spacing.transcriptLeading)
            .foregroundStyle(DS.Color.secondaryText)
            .textSelection(.enabled)
            .axLeaf("Card.Text.Translation")
    }

    private var labelledSpeaker: (raw: String, label: String)? {
        guard let raw = segment.speaker, let label = Self.speakerLabel(for: raw) else { return nil }
        return (raw, label)
    }

    private func speakerLine(speaker: (raw: String, label: String), isFavorite: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            speakerChip(raw: speaker.raw, label: speaker.label)
            Spacer(minLength: DS.Spacing.small)
            metaCluster(isFavorite: isFavorite)
        }
    }

    private func metaCluster(isFavorite: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.accent)
                    .accessibilityLabel("Favorite")
                    .axLeaf("Card.Badge.Favorite")
            }
            Button {
                if model.player != nil { model.seek(to: segment) }
            } label: {
                Text(Timecode.format(segment.start))
                    .font(model.monospacedTimestamps ? DS.Font.mono : DS.Font.secondary)
                    .foregroundStyle(isCurrent ? DS.Color.highlight : DS.Color.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Play from here")
            .axLeaf("Card.Button.SeekTimestamp")
            // A speakerless segment renders no chip, so the timestamp carries the assign menu too.
            .contextMenu { assignSpeakerMenu }
        }
        .fixedSize()
    }

    private func speakerChip(raw: String, label: String) -> some View {
        let person = model.person(forSpeaker: raw)
        return Button {
            assigningPerson = true
        } label: {
            Text(label)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(model.speakerColor(for: raw))
        }
        .buttonStyle(.plain)
        .help(person == nil
            ? String(localized: "Unknown speaker, click to assign")
            : String(localized: "Click to reassign this speaker"))
        .onHover { hovering in
            hoveredSpeaker.wrappedValue = hovering ? raw : nil
        }
        .popover(isPresented: $assigningPerson, arrowEdge: .bottom) {
            AssignSpeakerPopover(label: raw) {
                draftSpeakerName = label
                renamingSpeaker = true
            }
            .environment(model)
        }
        .contextMenu {
            Button("Rename \(label)…") {
                draftSpeakerName = label
                renamingSpeaker = true
            }
            assignSpeakerMenu
        }
        .axLeaf("Card.Button.Speaker")
    }

    @ViewBuilder
    private func noteRow(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.accent)
            Text(text)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.primaryText.opacity(0.85))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.small)
        .padding(.vertical, DS.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Color.accent.opacity(0.08))
        )
    }

    /// How much highlight the card under the playhead carries; the lit word is set on the result, so the contrast table pins it.
    static let currentCardTint = 0.10

    /// The viewer window draws the same card, so its outline is defined here rather than copied there.
    static func borderColor(isCurrent: Bool, hovering: Bool = false) -> Color {
        if isCurrent { return DS.Color.highlight.opacity(0.55) }
        if hovering { return DS.Color.accent.opacity(0.25) }
        return DS.Color.separator.opacity(0.6)
    }

    static func borderWidth(isCurrent: Bool) -> CGFloat { isCurrent ? 1.5 : 1 }

    private var cardBackground: Color {
        isCurrent ? DS.Color.highlight.opacity(Self.currentCardTint) : DS.Color.surfaceElevated
    }

    private func confidenceColor(_ bucket: SegmentConfidence.Bucket) -> Color {
        DS.confidenceColor(for: bucket).opacity(0.7)
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            TextField("Segment text", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Font.transcript)
                .lineLimit(1...20)
                .writingToolsBehavior(.complete)
                .focused($editingFocus)
                .onChange(of: editingFocus) { _, focused in
                    if !focused { endEditing(.commit) }
                }
                .onSubmit { endEditing(.commit) }
                .onKeyPress(.escape) {
                    endEditing(.cancel)
                    return .handled
                }
        } else if model.findIsOpen, !model.findQuery.isEmpty {
            highlightedText
                .font(DS.Font.transcript)
                .lineSpacing(DS.Spacing.transcriptLeading)
                .textSelection(.enabled)
        } else if showsWordKaraoke, let words = segment.words {
            karaoke(words: words)
                .font(DS.Font.transcript)
                .lineSpacing(DS.Spacing.transcriptLeading)
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
                .lineSpacing(DS.Spacing.transcriptLeading)
                .textSelection(.enabled)
        } else {
            Text(Self.displayText(segment.text))
                .font(DS.Font.transcript)
                .lineSpacing(DS.Spacing.transcriptLeading)
                .textSelection(.enabled)
        }
    }

    private func seekFromCard() {
        // hoveredSpeaker is set only while the pointer sits on the chip, which opens its popover instead.
        guard !isEditing, hoveredSpeaker.wrappedValue == nil, model.player != nil else { return }
        model.seek(to: segment)
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

    /// The strip holds the timing popover's anchor, so it outlives the hover while the popover is open.
    static func showsActionStrip(hovering: Bool, timingPopoverOpen: Bool, isEditing: Bool) -> Bool {
        (hovering || timingPopoverOpen) && !isEditing
    }

    private func actionStrip(isFavorite: Bool) -> some View {
        HStack(spacing: 4) {
            cardButton(
                systemName: isFavorite ? "star.fill" : "star",
                help: isFavorite ? "Remove from favorites" : "Add to favorites",
                tint: isFavorite ? DS.Color.accent : DS.Color.secondaryText,
                unavailableReason: libraryOnlyReason
            ) {
                model.toggleSegmentFavorite(segment.id)
            }
            .axLeaf("Card.Button.Favorite")
            cardButton(systemName: "pencil", help: "Edit") { beginEditing() }
                .axLeaf("Card.Button.Edit")
            cardButton(systemName: "note.text", help: "Add note", unavailableReason: libraryOnlyReason) {
                model.beginEditingNote(for: segment)
            }
            .axLeaf("Card.Button.Note")
            if model.player != nil {
                cardButton(systemName: "play.fill", help: "Play from here") {
                    model.seek(to: segment)
                }
                .axLeaf("Card.Button.Play")
            }
            cardButton(
                systemName: copied ? "checkmark" : "doc.on.doc",
                help: copied ? "Copied" : "Copy segment with timestamp"
            ) {
                copySegment()
            }
            .axLeaf("Card.Button.Copy")
            moreMenu(isFavorite: isFavorite)
        }
        .padding(.horizontal, DS.Spacing.snug)
        .padding(.vertical, DS.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular)
                .fill(DS.Color.surface)
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
        )
    }

    private func moreMenu(isFavorite: Bool) -> some View {
        Menu {
            Button(isFavorite ? "Unfavorite" : "Favorite") { model.toggleSegmentFavorite(segment.id) }
                .disabled(libraryOnlyReason != nil)
                .axLeaf("Card.Button.ToggleFavorite")
            Button("Nudge Timing…") { timingPopoverOpen = true }
                .axLeaf("Card.Button.Timing")
            Button("Split Segment") { splitSegment() }
                .axLeaf("Card.Button.Split")
            Button("Merge with Next Segment") { model.mergeSegmentWithNext(id: segment.id) }
                .disabled(isLastSegment)
                .axLeaf("Card.Button.Merge")
            Button("Copy Link to This Segment") { copyDeeplink() }
                .axLeaf("Card.Button.CopyLink")
            Divider()
            assignSegmentMenu
            Divider()
            Button("Delete Segment", role: .destructive) { model.deleteSegment(id: segment.id) }
                .axLeaf("Card.Button.Delete")
        } label: {
            Image(systemName: "ellipsis")
                .font(DS.Font.bodyStrong)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(DS.Color.secondaryText)
        .help("More actions")
        .accessibilityLabel("More actions")
        .axLeaf("Card.Menu.More")
        .popover(isPresented: $timingPopoverOpen, arrowEdge: .top) {
            SegmentTimingPopover(segment: segment)
                .environment(model)
        }
        // A popover follows its anchor out of the scroll view and past the window's edge.
        .onScrollVisibilityChange { visible in
            if !visible { timingPopoverOpen = false }
        }
    }

    private func cardButton(
        systemName: String,
        help: LocalizedStringKey,
        tint: Color = DS.Color.secondaryText,
        unavailableReason: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Font.bodyStrong)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .opacity(unavailableReason == nil ? 1 : DS.Opacity.disabled)
        .disabled(unavailableReason != nil)
        .help(unavailableReason ?? help)
        .accessibilityLabel(help)
    }

    /// Notes and favorites are kept on the library entry, so a batch result, fetched subtitles or a restored take has nowhere to put them.
    private var libraryOnlyReason: LocalizedStringKey? {
        model.selectedEntryID == nil ? "Save the transcript to the library first" : nil
    }

    private var isLastSegment: Bool {
        model.transcript?.segments.last?.id == segment.id
    }

    /// One segment's own people menu: the card's context menu and its ••• menu both show it, since
    /// a right-click over selectable text can land on the system editing menu instead.
    private var assignSegmentMenu: some View {
        Menu("Assign This Segment to") {
            ForEach(model.mostUsedPeople(limit: 10)) { person in
                Button(person.name) { model.assignSpeaker(person.name, toSegmentID: segment.id) }
                    .axLeaf("Card.MenuItem.AssignPerson.\(person.name)")
            }
            if !model.people.isEmpty { Divider() }
            Button("New person…") {
                draftAssignSpeakerName = ""
                assigningSpeaker = true
            }
            .axLeaf("Card.MenuItem.AssignNewPerson")
        }
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
        inlineEdit.begin()
        Task { @MainActor in editingFocus = true }
    }

    /// How an inline edit ends: Return and focus loss keep the draft, Escape throws it away.
    enum EditEnding {
        case commit
        case cancel

        /// The text to write back, or nil when the transcript stays as it is.
        func textToWrite(draft: String, original: String) -> String? {
            guard self == .commit, draft != original else { return nil }
            return draft
        }
    }

    /// Tracks whether an edit is open, so the focus loss that follows Return or Escape writes nothing the second time.
    struct InlineEdit {
        private(set) var isEditing = false

        mutating func begin() {
            isEditing = true
        }

        mutating func end(_ ending: EditEnding, draft: String, original: String) -> String? {
            guard isEditing else { return nil }
            isEditing = false
            return ending.textToWrite(draft: draft, original: original)
        }
    }

    private func endEditing(_ ending: EditEnding) {
        if let text = inlineEdit.end(ending, draft: draftText, original: segment.text) {
            model.editSegment(id: segment.id, newText: text)
        }
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
                piece.font = DS.Font.transcriptEmphasis
            }
            attr.append(piece)
        }
        return attr
    }

    private var highlightedText: Text {
        // Only cards holding a match read currentMatchIndex, so stepping through matches leaves the rest alone.
        let segmentMatches = model.matches.isEmpty ? [] : model.match(in: segment.id)
        return Text(TranscriptSearchHighlight.attributed(
            segment.text,
            matches: segmentMatches,
            currentMatchID: model.currentMatch?.id
        ))
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
                piece.font = DS.Font.transcriptEmphasis
            }
            attr.append(piece)
        }
        return attr
    }

    private func copySegment() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draggablePayload, forType: .string)
        copied = true
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
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
