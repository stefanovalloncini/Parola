import SwiftUI
import ParolaCore

/// What a row's badge says an entry is: its category, or for a transcription what it was made from.
enum EntrySourceKind: Equatable {
    case meeting
    case dictation
    case audio
    case video
    case web

    init(entry: LibraryEntry) {
        switch entry.category {
        case .meeting: self = .meeting
        case .dictation: self = .dictation
        case .transcription:
            switch entry.manifest.source {
            case .web: self = .web
            case .microphone, .systemAudio: self = .audio
            case .file: self.init(fileName: entry.manifest.originalAudioName)
            }
        }
    }

    init(fileName: String) {
        self.init(url: URL(fileURLWithPath: fileName))
    }

    /// Intake's own audio/video table answers this; a row must not grow a second one.
    init(url: URL) {
        self = BatchMediaKind(url: url) == .video ? .video : .audio
    }

    var symbol: String {
        switch self {
        case .meeting: return DS.categorySymbol(for: .meeting)
        case .dictation: return DS.categorySymbol(for: .dictation)
        case .audio: return "waveform"
        case .video: return "film"
        case .web: return "link"
        }
    }

    var tileFill: ThemeColor {
        switch self {
        case .meeting: return DS.KindTile.meeting
        case .dictation: return DS.KindTile.dictation
        case .audio: return DS.KindTile.audio
        case .video: return DS.KindTile.video
        case .web: return DS.KindTile.web
        }
    }

    var tint: Color {
        switch self {
        case .meeting: return DS.categoryTint(for: .meeting)
        case .dictation: return DS.categoryTint(for: .dictation)
        case .audio: return DS.mediaTint(for: .audio)
        case .video: return DS.mediaTint(for: .video)
        case .web: return DS.categoryTint(for: .transcription)
        }
    }
}

/// How tall every row of entries is, and where its parts sit.
enum EntryRowMetrics {
    static let height: CGFloat = 72
    /// The queue's own badge, which stays at the size its rows were drawn for.
    static let badgeSide: CGFloat = 28
    static let rowBadgeSide: CGFloat = 30
    /// The width a library list keeps its rows to, centred in a wider pane.
    static let columnWidth: CGFloat = 820
    /// Where a queue row's text starts, so what runs under a row lines up with its text instead of its badge.
    static let textInset: CGFloat = badgeSide + DS.Spacing.regular
    static let rowTextInset: CGFloat = rowBadgeSide + DS.Spacing.regular
    /// Wide enough for h:mm:ss under ten hours, so the snippets of a mixed list start on the same column.
    static let timecodeWidth: CGFloat = 52
    /// Wide enough for "23 h 59 min", so every row's time sits on the same column.
    static let durationWidth: CGFloat = 70
}

/// The tinted square a row or a job leads with.
struct EntryBadge: View {
    let kind: EntrySourceKind
    /// True only where the badge really sits on the accent fill; a grey selection keeps the tint.
    var onAccent: Bool = false
    var side: CGFloat = EntryRowMetrics.badgeSide

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(onAccent ? DS.Color.onAccentWash : kind.tint.opacity(0.14))
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: kind.symbol)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(onAccent ? DS.Color.onAccent : kind.tint)
            }
            .accessibilityHidden(true)
    }
}

/// A row's solid tile: the kind's own colour with a white glyph.
struct EntryTile: View {
    let kind: EntrySourceKind
    var side: CGFloat = EntryRowMetrics.rowBadgeSide
    /// True where the tile sits on the accent fill, where its edge needs a line to stay a tile.
    var onAccent = false

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
            .fill(LinearGradient(
                colors: [DS.KindTile.top(of: kind.tileFill).color, kind.tileFill.color], startPoint: .top, endPoint: .bottom
            ))
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: kind.symbol)
                    .font(.system(size: side * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                if onAccent {
                    RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                        .strokeBorder(DS.Color.onAccent.opacity(0.5), lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The line under a row's title: what the entry says, or where a search hit it.
enum EntryRowDetail {
    case excerpt(String?)
    case snippet(AttributedString, timecode: String?, reservesTimecode: Bool)
}

/// The one row every list of entries draws: the library, search results and Recently Deleted.
struct EntryRow<Accessory: View, Actions: View>: View {
    let display: LibraryRowDisplay
    var detail: EntryRowDetail = .excerpt(nil)
    var isSelected: Bool = false
    var help: String?
    /// Off for a caller that draws something under the row and washes the two together.
    var drawsHover: Bool = true
    /// A list that tracks one hovered row itself says so here, so a row scrolled from under the pointer lets go.
    var hovered: Bool?
    /// A control for the title line's trailing edge; its slot is kept free so the date and duration don't move when it appears.
    var titleAccessory: AnyView?
    let accessory: Accessory
    let trailingActions: Actions

    // Optional: AppKit can build a List cell after SwiftUI tore the List down, and a required read traps "No Observable object of type AppModel found".
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.backgroundProminence) private var backgroundProminence
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var isHovering = false

    init(
        display: LibraryRowDisplay,
        detail: EntryRowDetail = .excerpt(nil),
        isSelected: Bool = false,
        help: String? = nil,
        drawsHover: Bool = true,
        hovered: Bool? = nil,
        titleAccessory: AnyView? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder trailingActions: () -> Actions
    ) {
        self.display = display
        self.detail = detail
        self.isSelected = isSelected
        self.help = help
        self.drawsHover = drawsHover
        self.hovered = hovered
        self.titleAccessory = titleAccessory
        self.accessory = accessory()
        self.trailingActions = trailingActions()
    }

    private var detailText: AttributedString? {
        switch detail {
        case .excerpt(let text):
            guard let text, !text.isEmpty else { return nil }
            return AttributedString(text)
        case .snippet(let snippet, _, _):
            return snippet
        }
    }

    /// A search hit stays in the chrome's face, so its highlight reads as it always has.
    private var detailFont: Font {
        if case .snippet = detail { return DS.Font.body }
        return DS.Font.excerpt
    }

    /// Declaring the height keeps NSTableView off its uncached automatic-row-height path; accessibility sizes outgrow the constant, so they go back to measuring.
    private var rowHeight: CGFloat? {
        typeSize.isAccessibilitySize ? nil : EntryRowMetrics.height
    }

    /// The system flips `.secondary` white regardless of what `onAccent` solved to, so the row sets its own ink — the same one the badge and chips already use.
    private var secondaryStyle: Color {
        onAccent ? DS.Color.onAccentSecondary : DS.Color.secondaryText
    }

    /// A search hit keeps the secondary ink its highlight was tuned on; an excerpt reads as body text.
    private var detailStyle: Color {
        if onAccent { return DS.Color.onAccentSecondary }
        if case .snippet = detail { return DS.Color.secondaryText }
        return DS.Color.primaryText.opacity(colorScheme == .dark ? 0.6 : 0.72)
    }

    private var isHighlighted: Bool { hovered ?? isHovering }

    private var onAccent: Bool {
        DS.onAccent(isSelected: isSelected, prominence: backgroundProminence)
    }

    @ViewBuilder
    var body: some View {
        if hovered == nil {
            chromedRow
                .onHover { isHovering = $0 }
        } else {
            chromedRow
        }
    }

    /// Not on the whole row, or it would cover the trailing actions' own tooltips.
    private var rowHelp: String { help ?? display.tooltip }

    /// The row pads itself inside its hover wash, so the wash spans what the system selection spans.
    @ViewBuilder
    private var chromedRow: some View {
        let row = HStack(spacing: DS.Spacing.regular) {
            EntryTile(kind: display.sourceKind, onAccent: onAccent)
                .help(rowHelp)
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                detailLine
                    .help(rowHelp)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailingActions
        }
        .frame(minHeight: EntryRowMetrics.height)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)

        if drawsHover {
            row
                .padding(.horizontal, DS.Spacing.small)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(DS.Palette.divider.opacity(isSelected || isHighlighted ? 0 : 1))
                        .frame(height: 1 / displayScale)
                        .padding(.leading, DS.Spacing.small + EntryRowMetrics.rowTextInset)
                        .padding(.trailing, DS.Spacing.small)
                }
                .rowChrome(selected: isSelected, hovered: isHighlighted, selection: .native)
        } else {
            row
        }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.snug) {
            Text(display.title)
                .font(DS.Font.heading)
                .foregroundStyle(onAccent ? DS.Color.onAccent : DS.Color.primaryText)
                .lineLimit(1)
                .help(rowHelp)
            if display.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(secondaryStyle)
                    .accessibilityLabel("Pinned")
            }
            if display.noteCount > 0 { noteChip }
            labelChips
            if let language = display.language {
                chip {
                    HStack(spacing: 3) {
                        Image(systemName: "globe")
                            .accessibilityHidden(true)
                        Text(verbatim: language)
                    }
                }
            }
            Spacer(minLength: DS.Spacing.regular)
            Text(verbatim: display.when)
                .font(DS.Font.secondary)
                .monospacedDigit()
                .foregroundStyle(secondaryStyle)
                .lineLimit(1)
                .fixedSize()
            Text(verbatim: display.duration ?? "")
                .font(DS.Font.secondary)
                .monospacedDigit()
                .foregroundStyle(secondaryStyle)
                .lineLimit(1)
                .frame(width: EntryRowMetrics.durationWidth, alignment: .trailing)
                .accessibilityLabel(Text(verbatim: display.spokenDuration ?? ""))
                .accessibilityHidden(display.duration == nil)
            if titleAccessory != nil {
                Color.clear.frame(width: RowMenuSlot.width, height: 1)
            }
        }
        .overlay(alignment: .trailing) { titleAccessory }
    }

    private var detailLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            if case .snippet(_, let timecode, let reserves) = detail, reserves {
                // Hidden rather than empty: an empty Text sits on a different baseline and shifts the row.
                Text(timecode ?? "00:00")
                    .font(model?.monospacedTimestamps == true ? DS.Font.mono : DS.Font.secondary)
                    .foregroundStyle(secondaryStyle)
                    .lineLimit(1)
                    .opacity(timecode == nil ? 0 : 1)
                    .accessibilityLabel(Text("First match at \(timecode ?? "")"))
                    .accessibilityHidden(timecode == nil)
                    .frame(width: EntryRowMetrics.timecodeWidth, alignment: .leading)
            }
            if let detailText {
                Text(detailText)
                    .font(detailFont)
                    .foregroundStyle(detailStyle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            accessory
        }
    }

    private var noteChip: some View {
        HStack(spacing: 2) {
            Image(systemName: "note.text")
                .font(DS.Font.caption)
            Text(verbatim: AppFormat.integer(display.noteCount))
                .font(DS.Font.caption)
                .monospacedDigit()
        }
        .foregroundStyle(DS.Color.accentInk)
        .padding(.horizontal, DS.Spacing.tight)
        .padding(.vertical, 1)
        .background(Capsule().fill(DS.Color.accentWash))
    }

    @ViewBuilder
    private var labelChips: some View {
        let shown = Array(display.labels.prefix(2))
        let hidden = display.labels.count - shown.count
        if !shown.isEmpty {
            HStack(spacing: DS.Spacing.snug) {
                ForEach(shown, id: \.self) { label in
                    chip { Text(verbatim: label) }
                }
                if hidden > 0 {
                    chip { Text(verbatim: "+\(AppFormat.integer(hidden))") }
                }
            }
            .help(display.labels.joined(separator: ", "))
        }
    }

    /// Sized to its text so the title gives way first, and veiled in the foreground so it reads on a selected row's accent fill.
    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(DS.Font.caption)
            .monospacedDigit()
            .foregroundStyle(secondaryStyle)
            .lineLimit(1)
            .padding(.horizontal, DS.Spacing.snug)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(onAccent ? DS.Color.onAccentWash : DS.Palette.subtleFill)
            )
            .fixedSize()
    }
}

extension EntryRow where Accessory == EmptyView, Actions == EmptyView {
    init(
        display: LibraryRowDisplay,
        detail: EntryRowDetail = .excerpt(nil),
        isSelected: Bool = false,
        help: String? = nil,
        hovered: Bool? = nil
    ) {
        self.init(
            display: display,
            detail: detail,
            isSelected: isSelected,
            help: help,
            hovered: hovered,
            accessory: { EmptyView() },
            trailingActions: { EmptyView() }
        )
    }
}

extension EntryRow where Actions == EmptyView {
    init(
        display: LibraryRowDisplay,
        detail: EntryRowDetail = .excerpt(nil),
        isSelected: Bool = false,
        help: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.init(
            display: display,
            detail: detail,
            isSelected: isSelected,
            help: help,
            accessory: accessory,
            trailingActions: { EmptyView() }
        )
    }
}
