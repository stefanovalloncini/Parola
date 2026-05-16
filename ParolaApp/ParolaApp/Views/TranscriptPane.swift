import SwiftUI
import AVKit
import ParolaCore

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

enum TranscriptDisplayMode: String {
    case transcript
    case segments
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
    @State private var summarySheetOpen = false
    @State private var chatSheetOpen = false

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
            transcriptList

            if let player = model.player {
                Divider()
                if model.hasVideo {
                    PlayerSurface(player: player)
                        .frame(height: 200)
                        .background(Color.black)
                } else {
                    AudioTransportBar()
                        .padding(.horizontal, DS.Spacing.regular)
                        .padding(.vertical, DS.Spacing.small)
                }
            }
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let t = model.transcript {
                        ForEach(t.segments) { seg in
                            SegmentRow(segment: seg, isCurrent: seg.id == model.currentSegmentID)
                                .id(seg.id)
                                .onTapGesture { model.seek(to: seg) }
                        }
                    }
                }
                .padding(.vertical, 8)
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

// MARK: - Player

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

struct AudioTransportBar: View {
    @EnvironmentObject var model: AppModel
    @State private var scrubbingTo: Double?

    var body: some View {
        let duration = model.transcript?.durationSeconds ?? 0
        let progress = scrubbingTo ?? model.currentTimeSeconds

        HStack(spacing: DS.Spacing.regular) {
            Button(action: togglePlayPause) {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause" : "Play")

            Text(format(progress))
                .font(DS.Font.captionMono)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            if duration > 0 {
                Slider(
                    value: Binding(
                        get: { progress },
                        set: { scrubbingTo = $0 }
                    ),
                    in: 0...duration,
                    onEditingChanged: { editing in
                        if !editing, let target = scrubbingTo {
                            model.player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                            scrubbingTo = nil
                        }
                    }
                )
            } else {
                Slider(value: .constant(0), in: 0...1).disabled(true)
            }

            Text(format(duration))
                .font(DS.Font.captionMono)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(DS.Spacing.regular)
        .background(DS.Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
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
        }
    }

    private func format(_ t: Double) -> String {
        let total = Int(max(0, t.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let isCurrent: Bool

    @EnvironmentObject var model: AppModel
    @AppStorage("transcriptFontSize") private var fontSize: Int = 18
    @State private var draftText: String = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                Text(timestamp(segment.start))
                    .font(DS.Font.captionMono)
                    .foregroundStyle(DS.Color.secondaryText)
                if let speaker = segment.speaker {
                    Text(speaker)
                        .font(DS.Font.caption)
                        .foregroundStyle(speakerColor(for: speaker))
                }
            }
            .frame(width: 88, alignment: .leading)

            content
                .font(.system(size: CGFloat(fontSize)))
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.small)
        .background(isCurrent ? DS.Color.accent.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        if model.findIsOpen, !model.findQuery.isEmpty {
            highlightedText
        } else if isCurrent, model.karaokeHighlight, let words = segment.words, !words.isEmpty {
            karaoke(words: words)
        } else if isCurrent, model.karaokeHighlight, model.player != nil {
            syntheticKaraoke
        } else {
            TextField("Segment text", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...20)
                .focused($isEditing)
                .labelsHidden()
                .onAppear { draftText = segment.text }
                .onChange(of: segment.text) { _, newValue in
                    if !isEditing { draftText = newValue }
                }
                .onChange(of: isEditing) { _, focused in
                    if !focused, draftText != segment.text {
                        model.editSegment(id: segment.id, newText: draftText)
                    }
                }
        }
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

    private func speakerColor(for label: String) -> Color {
        DS.speakerColor(for: label)
    }

    private func timestamp(_ s: Double) -> String {
        Duration.seconds(s).formatted(
            .time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }
}
