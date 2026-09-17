import SwiftUI
import ParolaCore

struct RecentlyDeletedRow: View {
    static let expiryBarHeight: CGFloat = 3

    let display: LibraryRowDisplay
    let daysLeft: Int?
    let timeLeft: String
    let isSelected: Bool
    let onRestore: () -> Void
    let onPurge: () -> Void
    private let helpText: String
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        display: LibraryRowDisplay,
        daysLeft: Int?,
        timeLeft: String,
        isSelected: Bool = false,
        onRestore: @escaping () -> Void,
        onPurge: @escaping () -> Void
    ) {
        self.display = display
        self.daysLeft = daysLeft
        self.timeLeft = timeLeft
        self.isSelected = isSelected
        self.onRestore = onRestore
        self.onPurge = onPurge
        helpText = Self.helpText(deletedAt: display.entry.deletedAt, daysLeft: daysLeft)
    }

    private var entry: LibraryEntry { display.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.hair) {
            EntryRow(
                display: display,
                detail: .excerpt(display.excerpt),
                isSelected: isSelected,
                showsTimeOnly: false,
                help: helpText,
                drawsHover: false,
                accessory: { countdown },
                trailingActions: { actions }
            )
            expiryBar
        }
        .background(hoverWash)
        .animation(reduceMotion ? nil : DS.Motion.rowState, value: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button { onRestore() } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .axLeaf("Row.ContextMenuItem.Restore")
            Button(role: .destructive) { onPurge() } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
            .axLeaf("Row.ContextMenuItem.Purge")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(axLabel)
    }

    /// The preview the page loaded, or why there is none: an empty line would read as a lost transcript.
    static func previewText(_ preview: String?) -> String {
        guard let preview else { return String(localized: "Loading preview…") }
        return preview.isEmpty ? String(localized: "No transcript text.") : preview
    }

    // The List washes a selected row grey or accent depending on focus; only the system's own hierarchy reads on both.
    private var urgencyStyle: Color {
        isSelected ? .secondary : bucket.countdownColor
    }

    @ViewBuilder
    private var hoverWash: some View {
        if hovered, !isSelected {
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Palette.surfaceHover)
        }
    }

    private var countdown: some View {
        Text(timeLeft)
            .font(DS.Font.secondary)
            .foregroundStyle(urgencyStyle)
            .lineLimit(1)
            .fixedSize()
    }

    // Permanent deletion asks for the pointer first: a red trash on every resting row is a dare.
    private var actions: some View {
        HStack(spacing: DS.Spacing.tight) {
            Button(action: onRestore) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(DSIconChipButtonStyle())
            .help("Restore")
            .accessibilityLabel("Restore")
            .axLeaf("Row.Button.arrowuturnbackward")
            Button(action: onPurge) {
                Image(systemName: "trash")
                    .foregroundStyle(DS.Color.dangerText)
            }
            .buttonStyle(DSIconChipButtonStyle())
            .help("Delete Now")
            .accessibilityLabel("Delete Now")
            .axLeaf("Row.Button.trash")
        }
        .opacity(revealed ? 1 : 0)
        .allowsHitTesting(revealed)
    }

    @ViewBuilder
    private var expiryBar: some View {
        if let fraction = RecentlyDeletedCopy.remainingFraction(
            daysLeft: daysLeft,
            retentionDays: AppModel.trashRetentionDays
        ) {
            DSProgressBar(
                value: fraction,
                fill: isSelected ? .secondary : bucket.barFill,
                height: Self.expiryBarHeight
            )
            .padding(.leading, EntryRowMetrics.textInset)
            .accessibilityHidden(true)
        }
    }

    private var revealed: Bool { hovered || isSelected }

    private var bucket: RecentlyDeletedCopy.ExpiryBucket {
        RecentlyDeletedCopy.bucket(daysLeft: daysLeft)
    }

    private static func helpText(deletedAt: Date?, daysLeft: Int?) -> String {
        guard let deletedAt, let daysLeft else {
            return String(localized: "No deadline")
        }
        let deleted = AppFormat.dateAndTime(deletedAt)
        let due = AppFormat.day(
            RecentlyDeletedCopy.deadline(deletedAt: deletedAt, retentionDays: AppModel.trashRetentionDays)
        )
        return daysLeft < 0
            ? String(localized: "Deleted \(deleted) · was due \(due) · removed the next time Parola opens")
            : String(localized: "Deleted \(deleted) · due \(due)")
    }

    private var axLabel: String {
        "\(display.title), \(timeLeft), \(categoryName)"
    }

    private var categoryName: String {
        switch entry.category {
        case .transcription: return String(localized: "Transcription")
        case .meeting: return String(localized: "Meeting")
        case .dictation: return String(localized: "Dictation")
        }
    }
}

extension RecentlyDeletedCopy.ExpiryBucket {
    /// One reading of urgency: the section caption, the row's countdown and its bar all take their colour here.
    var countdownColor: Color {
        switch self {
        case .soon: return DS.Color.dangerText
        case .later: return DS.Color.secondaryText
        }
    }

    var barFill: Color {
        switch self {
        case .soon: return DS.Color.dangerText
        case .later: return DS.Color.accent
        }
    }
}
