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
            if entry.modelName.hasPrefix("youtube-") {
                self = .web
            } else {
                self.init(fileName: entry.manifest.originalAudioName)
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

/// What a row is tall, by density and by whether it has something to say under its title.
enum EntryRowMetrics {
    static let detail: CGFloat = 66
    static let compactDetail: CGFloat = 42
    /// The badge, not the text, is what a row with nothing to quote is as tall as.
    static let titleOnly: CGFloat = 44
    static let compactTitleOnly: CGFloat = 36
    static let badgeSide: CGFloat = 28
    /// Where a row's text starts, so a separator runs under the text instead of under the badge.
    static let textInset: CGFloat = badgeSide + DS.Spacing.regular
    /// Wide enough for h:mm:ss under ten hours, so the snippets of a mixed list start on the same column.
    static let timecodeWidth: CGFloat = 52

    static func height(compact: Bool, hasDetail: Bool) -> CGFloat {
        switch (compact, hasDetail) {
        case (false, true): return detail
        case (true, true): return compactDetail
        case (false, false): return titleOnly
        case (true, false): return compactTitleOnly
        }
    }
}

/// The tinted square a row or a job leads with.
struct EntryBadge: View {
    let kind: EntrySourceKind
    /// True only where the badge really sits on the accent fill; a grey selection keeps the tint.
    var onAccent: Bool = false
    var side: CGFloat = EntryRowMetrics.badgeSide

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(onAccent ? DS.Color.onAccent.opacity(0.18) : kind.tint.opacity(0.14))
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: kind.symbol)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(onAccent ? DS.Color.onAccent : kind.tint)
            }
            .accessibilityHidden(true)
    }
}

/// Who paints a row: a `List` paints its own selection, Home paints its own hover, anything else paints both.
enum EntryRowStyle {
    case list
    case home
    case plain
}

/// The line under a row's title: what the entry says, or where a search hit it.
enum EntryRowDetail {
    case excerpt(String?)
    case snippet(AttributedString, timecode: String?, reservesTimecode: Bool)
}

/// The one row every list of entries draws: Home Recent, the library lists, search results and Recently Deleted.
struct EntryRow<Accessory: View, Actions: View>: View {
    let display: LibraryRowDisplay
    var style: EntryRowStyle = .list
    var detail: EntryRowDetail = .excerpt(nil)
    var isSelected: Bool = false
    /// Grouped lists carry the day in their header, so their rows show the time of day instead.
    var showsTimeOnly: Bool = true
    var help: String?
    /// Off for a caller that draws something under the row and washes the two together.
    var drawsHover: Bool = true
    let accessory: Accessory
    let trailingActions: Actions

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.backgroundProminence) private var backgroundProminence
    @State private var isHovering = false

    init(
        display: LibraryRowDisplay,
        style: EntryRowStyle = .list,
        detail: EntryRowDetail = .excerpt(nil),
        isSelected: Bool = false,
        showsTimeOnly: Bool = true,
        help: String? = nil,
        drawsHover: Bool = true,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder trailingActions: () -> Actions
    ) {
        self.display = display
        self.style = style
        self.detail = detail
        self.isSelected = isSelected
        self.showsTimeOnly = showsTimeOnly
        self.help = help
        self.drawsHover = drawsHover
        self.accessory = accessory()
        self.trailingActions = trailingActions()
    }

    private var compact: Bool { model.sidebarDensity == "compact" }

    private var detailText: AttributedString? {
        switch detail {
        case .excerpt(let text):
            guard let text, !text.isEmpty else { return nil }
            return AttributedString(text)
        case .snippet(let snippet, _, _):
            return snippet
        }
    }

    private var detailLines: Int { compact ? 1 : 2 }

    /// Declaring the height keeps NSTableView off its uncached automatic-row-height path; accessibility sizes outgrow the constant, so they go back to measuring.
    private var rowHeight: CGFloat? {
        guard style == .list, !typeSize.isAccessibilitySize else { return nil }
        return EntryRowMetrics.height(compact: compact, hasDetail: detailText != nil)
    }

    /// The palette's secondary is a fixed grey; on the accent fill of a selected row only the system's flips with it.
    private var secondaryStyle: Color {
        isSelected ? .secondary : DS.Color.secondaryText
    }

    private var onAccent: Bool {
        DS.onAccent(isSelected: isSelected, prominence: backgroundProminence)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            EntryBadge(kind: display.sourceKind, onAccent: onAccent)
            VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                titleLine
                detailLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailingActions
        }
        .padding(.vertical, compact ? DS.Spacing.tight : DS.Spacing.small)
        .padding(.horizontal, style == .plain ? DS.Spacing.small : 0)
        .frame(height: rowHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .help(help ?? display.tooltip)
        .animation(reduceMotion ? nil : DS.Motion.rowState, value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.tight) {
                if display.pinned {
                    Image(systemName: "pin.fill")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.accent)
                }
                Text(display.title)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                if display.noteCount > 0 { noteChip }
            }
            Text(showsTimeOnly ? display.timeOfDay : display.shortDate)
                .font(DS.Font.secondary)
                .foregroundStyle(secondaryStyle)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: DS.Spacing.small)
            labelChips
            MetaLine(timecode: display.durationLabel, [display.languageLabel, display.modelLabel], tint: secondaryStyle)
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        HStack(alignment: .top, spacing: DS.Spacing.small) {
            if case .snippet(_, let timecode, let reserves) = detail, reserves {
                // Hidden rather than empty: an empty Text sits on a different baseline and shifts the row.
                Text(timecode ?? "00:00")
                    .font(model.monospacedTimestamps ? DS.Font.mono : DS.Font.secondary)
                    .foregroundStyle(secondaryStyle)
                    .lineLimit(1)
                    .opacity(timecode == nil ? 0 : 1)
                    .accessibilityLabel(Text("First match at \(timecode ?? "")"))
                    .accessibilityHidden(timecode == nil)
                    .frame(width: EntryRowMetrics.timecodeWidth, alignment: .leading)
            }
            if let detailText {
                Text(detailText)
                    .font(DS.Font.body)
                    .foregroundStyle(secondaryStyle)
                    .lineLimit(detailLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            accessory
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        switch style {
        case .list:
            if drawsHover, isHovering, !isSelected {
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(DS.Palette.surfaceHover)
            }
        case .home:
            EmptyView()
        case .plain:
            if isSelected {
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .fill(DS.Color.accent.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                            .strokeBorder(DS.Color.accent.opacity(0.35), lineWidth: 1)
                    )
            } else if isHovering {
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .fill(DS.Palette.surfaceHover)
            }
        }
    }

    private var noteChip: some View {
        HStack(spacing: 2) {
            Image(systemName: "note.text")
                .font(DS.Font.caption)
            Text(verbatim: AppFormat.integer(display.noteCount))
                .font(DS.Font.caption)
        }
        .foregroundStyle(DS.Color.accentText)
        .padding(.horizontal, DS.Spacing.tight)
        .padding(.vertical, 1)
        .background(Capsule().fill(DS.Color.accentWash))
    }

    @ViewBuilder
    private var labelChips: some View {
        let shown = Array(display.labels.prefix(2))
        let hidden = display.labels.count - shown.count
        if !shown.isEmpty {
            HStack(spacing: DS.Spacing.tight) {
                ForEach(shown, id: \.self) { label in
                    chip(Text(verbatim: label))
                }
                if hidden > 0 {
                    chip(Text(verbatim: "+\(AppFormat.integer(hidden))"))
                }
            }
            .help(display.labels.joined(separator: ", "))
        }
    }

    /// Sized to the text so it doesn't steal the excerpt's line, and veiled in the foreground so it reads on a selected row's accent fill.
    private func chip(_ label: Text) -> some View {
        label
            .font(DS.Font.caption)
            .foregroundStyle(secondaryStyle)
            .lineLimit(1)
            .padding(.horizontal, DS.Spacing.snug)
            .background(
                Capsule(style: .continuous)
                    .fill(onAccent ? DS.Color.onAccent.opacity(0.18) : DS.Color.surfaceElevated)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        onAccent ? DS.Color.onAccent.opacity(0.35) : DS.Color.separator.opacity(0.4),
                        lineWidth: 0.5
                    )
            )
    }
}

extension EntryRow where Accessory == EmptyView, Actions == EmptyView {
    init(
        display: LibraryRowDisplay,
        style: EntryRowStyle = .list,
        detail: EntryRowDetail = .excerpt(nil),
        isSelected: Bool = false,
        showsTimeOnly: Bool = true,
        help: String? = nil
    ) {
        self.init(
            display: display,
            style: style,
            detail: detail,
            isSelected: isSelected,
            showsTimeOnly: showsTimeOnly,
            help: help,
            accessory: { EmptyView() },
            trailingActions: { EmptyView() }
        )
    }
}

extension EntryRow where Actions == EmptyView {
    init(
        display: LibraryRowDisplay,
        style: EntryRowStyle = .list,
        detail: EntryRowDetail = .excerpt(nil),
        isSelected: Bool = false,
        showsTimeOnly: Bool = true,
        help: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.init(
            display: display,
            style: style,
            detail: detail,
            isSelected: isSelected,
            showsTimeOnly: showsTimeOnly,
            help: help,
            accessory: accessory,
            trailingActions: { EmptyView() }
        )
    }
}
