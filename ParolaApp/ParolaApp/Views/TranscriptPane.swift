import SwiftUI
import AVKit
import ParolaCore

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

enum TranscriptDisplayMode: String, CaseIterable, Identifiable {
    case transcript
    case segments
    var id: String { rawValue }
}

enum InspectorMode: String, CaseIterable, Identifiable {
    case format
    case info
    var id: String { rawValue }
}

struct TranscriptPane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("inspectorVisible") private var inspectorVisible: Bool = true
    @AppStorage("inspectorMode") private var inspectorModeRaw: String = InspectorMode.format.rawValue
    @AppStorage("transcriptDisplayMode") private var displayModeRaw: String = TranscriptDisplayMode.transcript.rawValue
    @State private var summarySheetOpen = false
    @State private var chatSheetOpen = false

    private var displayMode: TranscriptDisplayMode {
        TranscriptDisplayMode(rawValue: displayModeRaw) ?? .transcript
    }

    var body: some View {
        VStack(spacing: 0) {
            TranscriptHeaderBar(
                title: headerTitle,
                onAdvance: advanceToNext,
                onOpenSummary: { summarySheetOpen = true },
                onOpenChat: { chatSheetOpen = true }
            )
            Divider()

            if model.findIsOpen {
                FindBar()
            }

            HSplitView {
                transcriptColumn
                    .frame(minWidth: 320)

                if inspectorVisible {
                    TranscriptInspector(
                        mode: Binding(
                            get: { InspectorMode(rawValue: inspectorModeRaw) ?? .format },
                            set: { inspectorModeRaw = $0.rawValue }
                        ),
                        inspectorVisible: $inspectorVisible
                    )
                    .frame(minWidth: 280, idealWidth: 300, maxWidth: 340)
                }
            }
        }
        .sheet(isPresented: $summarySheetOpen) {
            SummarySheet().environmentObject(model)
        }
        .sheet(isPresented: $chatSheetOpen) {
            ChatSheet().environmentObject(model)
        }
    }

    private var headerTitle: String {
        if let url = model.sourceFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        if let entryID = model.selectedEntryID,
           let entry = model.libraryEntries.first(where: { $0.id == entryID }) {
            return entry.title
        }
        return "Untitled"
    }

    private func advanceToNext() {
        guard let segments = model.transcript?.segments, !segments.isEmpty else { return }
        if let current = model.currentSegmentID,
           let idx = segments.firstIndex(where: { $0.id == current }),
           idx + 1 < segments.count {
            model.seek(to: segments[idx + 1])
        } else if let first = segments.first {
            model.seek(to: first)
        }
    }

    private var transcriptColumn: some View {
        VStack(spacing: 0) {
            transcriptBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.hasVideo, let player = model.player {
                Divider()
                PlayerSurface(player: player)
                    .frame(height: 200)
                    .background(Color.black)
            }

            if model.player != nil {
                Divider()
                MediaBar()
            }
        }
    }

    @ViewBuilder
    private var transcriptBody: some View {
        switch displayMode {
        case .segments:
            SegmentsScroll()
        case .transcript:
            ContinuousTranscriptView()
        }
    }
}

private struct TranscriptHeaderBar: View {
    let title: String
    let onAdvance: () -> Void
    let onOpenSummary: () -> Void
    let onOpenChat: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Text(title)
                .font(DS.Font.heading)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onOpenSummary) {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .help("Summary")

            Button(action: onOpenChat) {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.borderless)
            .help("Chat with this transcript")

            Button(action: onAdvance) {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 22)
                    .background(
                        Capsule(style: .continuous)
                            .fill(DS.Color.surfaceElevated)
                    )
            }
            .buttonStyle(.plain)
            .help("Jump to next segment")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
    }
}

// MARK: - Inspector

private struct TranscriptInspector: View {
    @EnvironmentObject var model: AppModel
    @Binding var mode: InspectorMode
    @Binding var inspectorVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            modeRow
                .padding(.horizontal, DS.Spacing.regular)
                .padding(.vertical, DS.Spacing.small)
            Divider()

            ScrollView {
                Group {
                    switch mode {
                    case .format: FormatInspector()
                    case .info: InfoInspector()
                    }
                }
                .padding(DS.Spacing.regular)
            }
        }
        .background(DS.Color.surface)
    }

    private var modeRow: some View {
        HStack(spacing: DS.Spacing.tight) {
            InspectorModeIcon(systemName: "textformat", isOn: mode == .format) { mode = .format }
                .help("Format")
            InspectorModeIcon(systemName: "info.circle", isOn: mode == .info) { mode = .info }
                .help("Info")
            Spacer()
            InspectorModeIcon(systemName: "rectangle.righthalf.filled", isOn: false) {
                inspectorVisible = false
            }
            .help("Hide inspector")
        }
    }
}

private struct InspectorModeIcon: View {
    let systemName: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? DS.Color.accent.opacity(0.15) : Color.clear)
                )
                .foregroundStyle(isOn ? DS.Color.accent : DS.Color.primaryText)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Format inspector

private struct FormatInspector: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("transcriptDisplayMode") private var displayModeRaw: String = TranscriptDisplayMode.transcript.rawValue
    @AppStorage("transcriptFontSize") private var fontSize: Int = 18
    @AppStorage("transcriptFavoritesOnly") private var favoritesOnly: Bool = false
    @AppStorage("transcriptGroupUnnamed") private var groupUnnamed: Bool = false
    @State private var translateExpanded = false
    @State private var newSpeaker: String = ""

    private var displayMode: TranscriptDisplayMode {
        TranscriptDisplayMode(rawValue: displayModeRaw) ?? .transcript
    }

    var body: some View {
        VStack(spacing: DS.Spacing.medium) {
            copyButton

            displayModesCard

            InspectorGroup(title: "People") {
                TextField("Add a speaker…", text: $newSpeaker)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitSpeaker() }
            }

            InspectorDisclosureRow(title: "Translate to…", isExpanded: $translateExpanded) {
                Text("Translation runs as a separate pass.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }

            HStack {
                Text("Font Size")
                Spacer()
                Picker("Font Size", selection: $fontSize) {
                    ForEach([14, 16, 18, 20, 22, 24, 28], id: \.self) { size in
                        Text("\(size)").tag(size)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            Toggle("Favorites Only", isOn: $favoritesOnly)
                .toggleStyle(.switch)

            Toggle("Group segments without speakers", isOn: $groupUnnamed)
                .toggleStyle(.switch)
        }
    }

    private var copyButton: some View {
        Button {
            guard let t = model.transcript else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t.text, forType: .string)
        } label: {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: "doc.on.doc")
                Text("Copy")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.small)
            .background(
                Capsule(style: .continuous)
                    .fill(DS.Color.surfaceElevated)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.transcript == nil)
    }

    private var displayModesCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                DisplayModeCard(
                    title: "Transcript",
                    icon: "text.alignleft",
                    isSelected: displayMode == .transcript
                ) { displayModeRaw = TranscriptDisplayMode.transcript.rawValue }

                DisplayModeCard(
                    title: "Segments",
                    icon: "list.bullet.below.rectangle",
                    isSelected: displayMode == .segments
                ) { displayModeRaw = TranscriptDisplayMode.segments.rawValue }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Display Modes")
                    .font(DS.Font.heading)
                Text("Toggle between transcript and segment layouts.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .padding(DS.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
        }
    }

    private func commitSpeaker() {
        let trimmed = newSpeaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { [peopleStore = model.peopleStore] in
            _ = await peopleStore.recordUsage(name: trimmed)
        }
        newSpeaker = ""
    }
}

private struct DisplayModeCard: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Spacing.small) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                Text(title).font(DS.Font.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.medium)
            .background(DS.Color.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.regular)
                    .strokeBorder(isSelected ? DS.Color.accent : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
        }
        .buttonStyle(.plain)
    }
}

private struct InspectorGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorDisclosureRow<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Button { isExpanded.toggle() } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
    }
}

// MARK: - Info inspector

private struct InfoInspector: View {
    @EnvironmentObject var model: AppModel

    private var entry: LibraryEntry? {
        guard let id = model.selectedEntryID else { return nil }
        return model.libraryEntries.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            InfoSection(title: "Model & Language") {
                InfoRow(icon: "cube", label: "Model", value: model.transcript?.modelName ?? "—")
                InfoRow(icon: "globe", label: "Language", value: languageLabel)
            }

            InfoSection(title: "Properties") {
                InfoRow(icon: "clock", label: "Audio Duration", value: durationLabel)
                InfoRow(icon: "calendar", label: "Created", value: dateLabel(entry?.createdAt))
                InfoRow(icon: "calendar.badge.clock", label: "Updated", value: dateLabel(entry?.createdAt))
            }

            InfoSection(title: "Transcription Details") {
                InfoRow(icon: "globe", label: "Model Language", value: languageLabel)
                InfoRow(icon: "cube", label: "Model", value: model.transcript?.modelName ?? "—")
                InfoRow(icon: "cpu", label: "Engine", value: "WhisperKit")
                InfoRow(icon: "character", label: "Characters", value: "\(charCount)")
                InfoRow(icon: "text.word.spacing", label: "Words", value: "\(wordCount)")
            }

            InfoSection(title: "Transcription Quality Feedback") {
                HStack(spacing: DS.Spacing.small) {
                    FeedbackPill(icon: "hand.thumbsup", title: "Accurate")
                    FeedbackPill(icon: "hand.thumbsdown", title: "Not Accurate")
                }
            }
        }
    }

    private var languageLabel: String {
        guard let code = model.transcript?.language, !code.isEmpty else { return "Auto" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    private var durationLabel: String {
        guard let d = model.transcript?.durationSeconds else { return "—" }
        return Duration.seconds(d).formatted(.time(pattern: .hourMinuteSecond))
    }

    private func dateLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var charCount: Int {
        model.transcript?.text.count ?? 0
    }

    private var wordCount: Int {
        guard let text = model.transcript?.text else { return 0 }
        return text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InfoRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: icon)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 16)
            Text(label).foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(DS.Font.body)
    }
}

private struct FeedbackPill: View {
    let icon: String
    let title: String

    var body: some View {
        Button {} label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.small)
            .background(DS.Color.surfaceElevated)
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Summary & Chat sheets

private struct SummarySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Summary").font(DS.Font.heading)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(DS.Spacing.regular)
            Divider()
            SummaryPane()
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

private struct ChatSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat").font(DS.Font.heading)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(DS.Spacing.regular)
            Divider()
            ChatPane()
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

// MARK: - Segments mode

struct SegmentsScroll: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.small) {
                    if let t = model.transcript {
                        ForEach(t.segments) { seg in
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
        }
    }
}

struct SegmentCard: View {
    let segment: TranscriptSegment
    let isCurrent: Bool

    @EnvironmentObject var model: AppModel
    @State private var hovering: Bool = false
    @State private var isEditing: Bool = false
    @State private var draftText: String = ""
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
                }
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
        .onHover { hover in
            withAnimation(.easeOut(duration: 0.12)) { hovering = hover }
        }
        .onTapGesture {
            if !isEditing { model.seek(to: segment) }
        }
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

    private var actionStrip: some View {
        HStack(spacing: 2) {
            cardButton(systemName: "pencil", help: "Edit") { beginEditing() }
            cardButton(systemName: "play.fill", help: "Play from here") {
                model.seek(to: segment)
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

    private func timestamp(_ s: Double) -> String {
        Duration.seconds(s).formatted(
            .time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }
}

// MARK: - Continuous mode

struct ContinuousTranscriptView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ContinuousParagraph()
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.vertical, DS.Spacing.large)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct ContinuousParagraph: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering: Bool = false
    @State private var cursor: CGPoint = .zero

    var body: some View {
        attributedText
            .font(.system(size: 18, weight: .regular))
            .lineSpacing(6)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hovering = true
                    cursor = location
                case .ended:
                    hovering = false
                }
            }
            .overlay(alignment: .topLeading) {
                if hovering, let seg = playTarget {
                    Button {
                        model.seek(to: seg)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(DS.Color.accent))
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Play from here")
                    .offset(x: cursor.x - 30, y: cursor.y - 11)
                }
            }
    }

    private var playTarget: TranscriptSegment? {
        guard let segments = model.transcript?.segments, !segments.isEmpty else { return nil }
        if let currentID = model.currentSegmentID,
           let seg = segments.first(where: { $0.id == currentID }) {
            return seg
        }
        return segments.first
    }

    private var attributedText: Text {
        guard let transcript = model.transcript else { return Text("") }
        var attr = AttributedString()
        let currentID = model.currentSegmentID
        let segments = transcript.segments

        for (idx, seg) in segments.enumerated() {
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            var piece = AttributedString(body + (idx == segments.count - 1 ? "" : " "))
            if seg.id == currentID {
                piece.foregroundColor = DS.Color.accent
            }
            attr.append(piece)
        }
        return Text(attr)
    }
}

// MARK: - Media bar

struct MediaBar: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("playbackRate") private var playbackRate: Double = 1.0
    @State private var scrubbingTo: Double?

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        let duration = model.transcript?.durationSeconds ?? 0
        let progress = scrubbingTo ?? model.currentTimeSeconds

        HStack(spacing: DS.Spacing.regular) {
            Button(action: togglePlayPause) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(DS.Color.accent))
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause" : "Play")

            ScrubberTrack(
                progress: progress,
                duration: duration,
                onScrub: { scrubbingTo = $0 },
                onCommit: { target in
                    model.player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                    scrubbingTo = nil
                }
            )
            .frame(height: 18)

            Text(timeLabel(current: progress, total: duration))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 96, alignment: .trailing)

            Menu {
                ForEach(speeds, id: \.self) { s in
                    Button {
                        playbackRate = s
                        applyRate()
                    } label: {
                        if abs(s - playbackRate) < 0.001 {
                            Label(speedLabel(s), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(s))
                        }
                    }
                }
            } label: {
                Text(speedLabel(playbackRate))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(DS.Color.accent.opacity(0.14))
                    )
                    .overlay(
                        Capsule().stroke(DS.Color.accent.opacity(0.35), lineWidth: 1)
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .frame(height: 52)
        .background(DS.Color.surfaceElevated)
        .onAppear { applyRate() }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { applyRate() }
        }
    }

    private func togglePlayPause() {
        guard let player = model.player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            let duration = model.transcript?.durationSeconds ?? 0
            if duration > 0, model.currentTimeSeconds >= duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
            applyRate()
        }
    }

    private func applyRate() {
        guard let player = model.player else { return }
        player.defaultRate = Float(playbackRate)
        if player.timeControlStatus == .playing {
            player.rate = Float(playbackRate)
        }
    }

    private func speedLabel(_ value: Double) -> String {
        if value == floor(value) {
            return "\(Int(value))×"
        }
        return "\(value)×"
    }

    private func timeLabel(current: Double, total: Double) -> String {
        "\(format(current)) / \(format(total))"
    }

    private func format(_ t: Double) -> String {
        let total = Int(max(0, t.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

private struct ScrubberTrack: View {
    let progress: Double
    let duration: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let ratio = duration > 0 ? min(1, max(0, progress / duration)) : 0
            let knobX = width * ratio

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Color.separator.opacity(0.5))
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .center)

                Capsule()
                    .fill(DS.Color.accent)
                    .frame(width: knobX, height: 4)
                    .frame(maxHeight: .infinity, alignment: .center)

                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(DS.Color.accent, lineWidth: 2))
                    .frame(width: isDragging ? 14 : 12, height: isDragging ? 14 : 12)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .offset(x: knobX - (isDragging ? 7 : 6))
                    .opacity(duration > 0 ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        isDragging = true
                        let x = min(max(0, value.location.x), width)
                        onScrub(Double(x / width) * duration)
                    }
                    .onEnded { value in
                        guard duration > 0, width > 0 else { return }
                        let x = min(max(0, value.location.x), width)
                        onCommit(Double(x / width) * duration)
                        isDragging = false
                    }
            )
        }
        .disabled(duration <= 0)
    }
}

// MARK: - Info card

struct TranscriptInfoCard: View {
    let transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.tight) {
            row("Language", value: transcript.language.uppercased())
            row("Model", value: transcript.modelName)
            row("Segments", value: "\(transcript.segments.count)")
            if let d = transcript.durationSeconds {
                row("Duration", value: Duration.seconds(d).formatted(.time(pattern: .hourMinuteSecond)))
            }
        }
        .padding(DS.Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
        .font(.callout)
    }
}
