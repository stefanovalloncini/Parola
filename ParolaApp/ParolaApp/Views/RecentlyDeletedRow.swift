import SwiftUI
import ParolaCore

struct RecentlyDeletedRow: View {
    let display: LibraryRowDisplay
    let daysLeft: Int?
    let timeLeft: String
    let isSelected: Bool
    let isPurging: Bool
    let showsSeparator: Bool
    let onRestore: () -> Void
    let onPurge: () -> Void
    let onTap: () -> Void
    private let helpText: String
    @State private var hovered = false

    init(
        display: LibraryRowDisplay,
        daysLeft: Int?,
        timeLeft: String,
        isSelected: Bool = false,
        isPurging: Bool = false,
        showsSeparator: Bool = true,
        onRestore: @escaping () -> Void,
        onPurge: @escaping () -> Void,
        onTap: @escaping () -> Void
    ) {
        self.display = display
        self.daysLeft = daysLeft
        self.timeLeft = timeLeft
        self.isSelected = isSelected
        self.isPurging = isPurging
        self.showsSeparator = showsSeparator
        self.onRestore = onRestore
        self.onPurge = onPurge
        self.onTap = onTap
        helpText = Self.helpText(deletedAt: display.entry.deletedAt, daysLeft: daysLeft)
    }

    private var entry: LibraryEntry { display.entry }

    var body: some View {
        EntryRow(
            display: display,
            style: .plain,
            detail: .excerpt(display.excerpt),
            isSelected: isSelected,
            showsTimeOnly: false,
            help: helpText,
            accessory: { meterLine },
            trailingActions: { actions }
        )
        .overlay(alignment: .bottom) { separator }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onTap() }
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

    /// The preview the sheet loaded, or why there is none: an empty line would read as a lost transcript.
    static func previewText(_ preview: String?) -> String {
        guard let preview else { return String(localized: "Loading preview…") }
        return preview.isEmpty ? String(localized: "No transcript text.") : preview
    }

    private var actions: some View {
        HStack(spacing: DS.Spacing.tight) {
            RecentlyDeletedCardIconButton(
                systemName: "arrow.uturn.backward",
                help: "Restore",
                hoverTint: DS.Palette.success,
                action: onRestore
            )
            .opacity(revealed ? 1 : 0.55)
            // Permanent deletion asks for the pointer first: a red trash on every resting row is a dare.
            RecentlyDeletedCardIconButton(
                systemName: "trash",
                help: "Delete Permanently",
                tint: DS.Color.danger,
                action: onPurge
            )
            .opacity(revealed ? 1 : 0)
            .allowsHitTesting(revealed)
        }
    }

    @ViewBuilder
    private var meterLine: some View {
        HStack(spacing: DS.Spacing.small) {
            if let daysLeft, entry.deletedAt != nil {
                DecayStrip(
                    daysRemaining: daysLeft,
                    totalDays: AppModel.trashRetentionDays,
                    seed: entry.id,
                    liveColor: tier.stripColor,
                    collapsed: isPurging
                )
            }
            Text(timeLeft)
                .font(tier == .calm ? DS.Font.mono : DS.Font.calloutMonoEmphasized)
                .foregroundStyle(tier.color)
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var separator: some View {
        if showsSeparator {
            Rectangle()
                .fill(DS.Color.separator.opacity(0.5))
                .frame(height: 1)
                .padding(.leading, DS.Spacing.small + EntryRowMetrics.textInset)
                .padding(.trailing, DS.Spacing.small)
        }
    }

    private var revealed: Bool { hovered || isSelected }

    private var tier: RecentlyDeletedCopy.Tier {
        RecentlyDeletedCopy.tier(daysLeft: daysLeft)
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

extension RecentlyDeletedCopy.Tier {
    /// The one tier-to-text mapping: the row's countdown and the group header above it read it alike.
    var color: Color {
        switch self {
        case .calm, .undated: return DS.Color.secondaryText
        case .soon: return DS.Color.warningText
        case .critical, .overdue: return DS.Color.dangerText
        }
    }

    var stripColor: Color {
        switch self {
        case .calm: return DS.Color.secondaryText.opacity(0.55)
        case .soon: return DS.Palette.warning
        case .critical, .overdue: return DS.Color.danger
        case .undated: return DS.Color.separator
        }
    }
}

struct DecayStrip: View, Animatable {
    let daysRemaining: Int
    let totalDays: Int
    let seed: String
    let liveColor: Color
    let barWidth: CGFloat
    let spacing: CGFloat
    let height: CGFloat
    let idleHeight: CGFloat
    private var collapse: Double

    init(
        daysRemaining: Int,
        totalDays: Int,
        seed: String,
        liveColor: Color,
        barWidth: CGFloat = 2,
        spacing: CGFloat = 1.5,
        height: CGFloat = 14,
        idleHeight: CGFloat = 2,
        collapsed: Bool = false
    ) {
        self.daysRemaining = daysRemaining
        self.totalDays = totalDays
        self.seed = seed
        self.liveColor = liveColor
        self.barWidth = barWidth
        self.spacing = spacing
        self.height = height
        self.idleHeight = idleHeight
        self.collapse = collapsed ? 1 : 0
    }

    nonisolated var animatableData: Double {
        get { collapse }
        set { collapse = newValue }
    }

    var body: some View {
        Canvas(opaque: false) { context, size in
            let spentColor = DS.Color.separator.opacity(0.55)
            let base = seedHash
            let standing = daysRemaining < 0 ? 0 : 1 - collapse
            for index in 0..<max(0, totalDays) {
                let live = index >= firstLiveBar
                let barHeight = live
                    ? idleHeight + (height - idleHeight) * amplitude(at: index, base: base) * standing
                    : idleHeight
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: (size.height - barHeight) / 2, width: barWidth, height: barHeight)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2, style: .continuous),
                    with: .color(live ? liveColor : spentColor)
                )
            }
        }
        .frame(width: contentWidth, height: height)
        .accessibilityHidden(true)
    }

    private var contentWidth: CGFloat {
        CGFloat(totalDays) * barWidth + CGFloat(max(0, totalDays - 1)) * spacing
    }

    // One bar always stays live, so a spent strip reads as flatlined rather than as a failed draw.
    private var firstLiveBar: Int {
        totalDays - max(1, min(max(daysRemaining, 0), totalDays))
    }

    private var seedHash: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for scalar in seed.unicodeScalars {
            hash = (hash ^ UInt64(scalar.value)) &* 0x100000001b3
        }
        return hash
    }

    private func amplitude(at index: Int, base: UInt64) -> Double {
        let hash = (base ^ UInt64(index)) &* 0x100000001b3
        return 0.45 + 0.55 * Double(hash % 1_000) / 999
    }
}

struct RecentlyDeletedCardIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var tint: Color = .primary
    var hoverTint: Color? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Font.subheadlineEmphasized)
                .foregroundStyle(hovered ? (hoverTint ?? tint) : tint.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .fill(hovered ? DS.Palette.surfaceHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .axLeaf("Row.Button.\(systemName.replacingOccurrences(of: ".", with: ""))")
    }
}
