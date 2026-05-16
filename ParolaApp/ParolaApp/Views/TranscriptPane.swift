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

struct TranscriptPane: View {
    @EnvironmentObject var model: AppModel
    @State private var rightTab: RightTab = .player

    enum RightTab { case player, summary }

    var body: some View {
        VStack(spacing: 0) {
            if model.findIsOpen {
                FindBar()
            }
            HSplitView {
                transcriptList
                    .frame(minWidth: 320)

                rightColumn
                    .frame(minWidth: 320)
            }
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        VStack(spacing: 0) {
            Picker("Right pane", selection: $rightTab) {
                Text("Player").tag(RightTab.player)
                Text("Summary").tag(RightTab.summary)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.top, DS.Spacing.regular)

            Divider().padding(.top, DS.Spacing.small)

            switch rightTab {
            case .player: playerColumn
            case .summary: SummaryPane()
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

    @ViewBuilder
    private var playerColumn: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            if model.hasVideo, let player = model.player {
                PlayerSurface(player: player)
                    .frame(height: 220)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
                    .padding(.horizontal, DS.Spacing.regular)
                    .padding(.top, DS.Spacing.regular)
            } else if model.player != nil {
                AudioTransportBar()
                    .padding(.horizontal, DS.Spacing.regular)
                    .padding(.top, DS.Spacing.regular)
            }

            if let t = model.transcript {
                TranscriptInfoCard(transcript: t)
                    .padding(.horizontal, DS.Spacing.regular)
            }

            Spacer()

            HStack(spacing: DS.Spacing.small) {
                Button {
                    if let t = model.transcript {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(t.text, forType: .string)
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Spacer()
                Menu {
                    Button("As Plain Text…") { model.exportRequest(.txt) }
                    Button("As Markdown…") { model.exportRequest(.md) }
                    Button("As SubRip (.srt)…") { model.exportRequest(.srt) }
                    Button("As WebVTT (.vtt)…") { model.exportRequest(.vtt) }
                    Button("As JSON…") { model.exportRequest(.json) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.bottom, DS.Spacing.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

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
                .font(DS.Font.transcript)
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
