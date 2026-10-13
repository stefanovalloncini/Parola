import AppKit
import SwiftUI
import ParolaCore

/// The newest takes as tiles above the list: what you most likely came back for, larger than the rest.
struct RecentShelf: View {
    let rows: [LibraryRowDisplay]
    @Binding var selection: Set<LibraryEntry.ID>
    let cursor: LibraryEntry.ID?
    let rename: (LibraryEntry) -> Void
    let delete: (Set<LibraryEntry.ID>) -> Void
    let choose: (LibraryEntry.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text("Recent")
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.primaryText)
                .padding(.top, DS.Spacing.regular)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: RecentShelfRules.tileSpacing) {
                ForEach(rows) { row in
                    RecentTile(
                        row: row,
                        isSelected: selection.contains(row.id),
                        hasFocus: cursor == row.id,
                        rename: rename,
                        delete: delete,
                        select: { choose(row.id) }
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent")
        .accessibilityAddTraits(.isHeader)
    }
}

struct RecentTile: View {
    let row: LibraryRowDisplay
    let isSelected: Bool
    let hasFocus: Bool
    let rename: (LibraryEntry) -> Void
    let delete: (Set<LibraryEntry.ID>) -> Void
    let select: () -> Void

    // Optional: AppKit can build a List cell after SwiftUI tore the List down, and a required read traps "No Observable object of type AppModel found".
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    static func open(_ id: LibraryEntry.ID, inNewWindow: Bool, in model: AppModel?) {
        model?.openEntryFromLibrary(id, inNewWindow: inNewWindow)
    }

    /// Option opens in a window of its own, as it does on a row.
    private static var optionIsDown: Bool { NSEvent.modifierFlags.contains(.option) }

    private var look: RecentShelfRules.SelectionLook {
        RecentShelfRules.selectionLook(
            isSelected: isSelected, hasFocus: hasFocus, windowIsKey: controlActiveState == .key
        )
    }

    private var onAccent: Bool { look == .active }
    private var primaryInk: Color { onAccent ? DS.Color.onAccent : DS.Color.primaryText }
    private var secondaryInk: Color { onAccent ? DS.Color.onAccentSecondary : DS.Color.secondaryText }

    private var excerptInk: Color {
        if onAccent { return DS.Color.onAccent }
        return DS.Color.primaryText.opacity(colorScheme == .dark ? 0.66 : 0.78)
    }

    private var fill: Color {
        switch look {
        case .none: return DS.Palette.surface
        case .active: return DS.Color.accentFill
        case .inactive: return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
    }

    var body: some View {
        let lift: CGFloat = isHovering ? -2 : 0
        return content
            .padding(DS.Spacing.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .fill(fill)
                    .shadow(color: .black.opacity(isHovering ? 0.12 : 0.04), radius: isHovering ? 8 : 3, y: isHovering ? 3 : 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .strokeBorder(isHovering && look == .none ? DS.Color.primaryText.opacity(0.16) : DS.Palette.divider, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .visualEffect { content, _ in content.offset(y: lift) }
            .animation(reduceMotion ? nil : DS.Motion.rowState, value: isHovering)
            .onHover { isHovering = $0 }
            .gesture(
                TapGesture(count: 2).onEnded { Self.open(row.id, inNewWindow: Self.optionIsDown, in: model) }
                    .simultaneously(with: TapGesture().onEnded { select() })
            )
            .contextMenu {
                if let model {
                    LibraryRowMenu(model: model, entries: [row.entry], rename: rename, delete: delete)
                }
            }
            .draggable(containerItemID: row.id)
            .help(row.tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: LibraryRowFormat.spokenLabel(for: row, detail: [row.excerpt ?? ""])))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select() }
            .accessibilityActions {
                if let model { LibraryRowActionButtons(model: model, entry: row.entry, rename: rename) }
            }
            .accessibilityIdentifier("library.shelf.\(row.id)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                EntryTile(kind: row.sourceKind, side: 36, onAccent: onAccent)
                Spacer(minLength: DS.Spacing.small)
                if let duration = row.duration {
                    Text(verbatim: duration)
                        .font(DS.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(secondaryInk)
                        .padding(.horizontal, DS.Spacing.snug)
                        .padding(.vertical, DS.Spacing.hair)
                        .background(Capsule().fill(onAccent ? DS.Color.onAccentWash : DS.Palette.subtleFill))
                }
            }
            Text(row.title)
                .font(DS.Font.heading)
                .foregroundStyle(primaryInk)
                .lineLimit(1)
                .padding(.top, DS.Spacing.small)
            Text(verbatim: row.when)
                .font(DS.Font.body)
                .foregroundStyle(secondaryInk)
                .lineLimit(1)
                .padding(.top, DS.Spacing.tight)
            Text(verbatim: row.excerpt ?? " ")
                .font(DS.Font.excerpt)
                .lineSpacing(2)
                .foregroundStyle(excerptInk)
                .lineLimit(3, reservesSpace: true)
                .padding(.top, DS.Spacing.small)
        }
    }
}
