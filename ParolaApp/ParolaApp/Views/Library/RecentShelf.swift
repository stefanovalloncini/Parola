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
                .accessibilityAddTraits(.isHeader)
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent")
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
    @State private var isHovering = false

    static func open(_ id: LibraryEntry.ID, in model: AppModel?) {
        guard let request = LibraryListContent.openRequest(for: [id], modifiers: NSEvent.modifierFlags) else { return }
        model?.openEntryFromLibrary(request.id, inNewWindow: request.inNewWindow)
    }

    private var look: RecentShelfRules.SelectionLook {
        RecentShelfRules.selectionLook(
            isSelected: isSelected, hasFocus: hasFocus, windowIsKey: controlActiveState == .key
        )
    }

    private var onAccent: Bool { look == .active }
    private var primaryInk: Color { onAccent ? DS.Color.onAccent : DS.Color.primaryText }
    private var secondaryInk: Color { onAccent ? DS.Color.onAccentSecondary : DS.Color.secondaryText }

    private var fill: Color {
        switch look {
        case .none: return DS.Palette.surface
        case .active: return DS.Color.accentFill
        case .inactive: return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: RecentShelfRules.tileHeight, maxHeight: RecentShelfRules.tileHeight, alignment: .topLeading)
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
            .offset(y: isHovering ? -2 : 0)
            .animation(reduceMotion ? nil : DS.Motion.rowState, value: isHovering)
            .onHover { isHovering = $0 }
            .gesture(
                TapGesture(count: 2).onEnded { Self.open(row.id, in: model) }
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
            .accessibilityActions {
                if let model { LibraryRowActionButtons(model: model, entry: row.entry, rename: rename) }
            }
            .accessibilityIdentifier("library.shelf.\(row.id)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                EntryTile(kind: row.sourceKind, side: 36, onAccent: onAccent)
                Spacer(minLength: DS.Spacing.small)
                if let duration = row.duration {
                    Text(verbatim: duration)
                        .font(DS.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(secondaryInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(onAccent ? DS.Color.onAccentWash : DS.Palette.subtleFill))
                }
            }
            .padding(.bottom, DS.Spacing.tight)
            Text(row.title)
                .font(DS.Font.heading)
                .foregroundStyle(primaryInk)
                .lineLimit(1)
            Text(verbatim: row.when)
                .font(DS.Font.body)
                .foregroundStyle(secondaryInk)
                .lineLimit(1)
            if let excerpt = row.excerpt {
                Text(verbatim: excerpt)
                    .font(DS.Font.excerpt)
                    .lineSpacing(2)
                    .foregroundStyle(onAccent ? DS.Color.onAccent : DS.Color.primaryText.opacity(0.78))
                    .lineLimit(4)
                    .padding(.top, 2)
            }
        }
    }
}
