import SwiftUI

/// Written by hand rather than with `@Entry`: the macro warns about storing a closure it cannot compare.
private struct SelectRuleRowKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

extension EnvironmentValues {
    /// Selects the rule-list row a field sits in, so − removes the row being edited.
    var selectRuleRow: (@MainActor @Sendable () -> Void)? {
        get { self[SelectRuleRowKey.self] }
        set { self[SelectRuleRowKey.self] = newValue }
    }
}

extension View {
    /// A field in a rule-list row chooses its row when it takes the keyboard.
    func selectsRuleRowOnFocus() -> some View {
        modifier(SelectsRuleRowOnFocus())
    }
}

/// An editable list's rows as one keyboard stop: Tab lands on the chosen row, ↑ and ↓ choose, ⌫ removes.
struct RuleListRows<Item: Identifiable, Row: View>: View where Item.ID: Sendable {
    private let items: [Item]
    @Binding private var selection: Item.ID?
    private let leaf: String
    private let removeLabel: LocalizedStringKey
    private let asksBeforeRemoving: Bool
    private let onRemove: (Item.ID) -> Void
    private let row: (Item) -> Row

    @FocusState private var focused: Item.ID?
    /// The row that keeps the keyboard after its neighbour was removed, with nothing chosen.
    @State private var anchor: Item.ID?

    init(
        _ items: [Item], selection: Binding<Item.ID?>, leaf: String, removeLabel: LocalizedStringKey,
        asksBeforeRemoving: Bool = false, onRemove: @escaping (Item.ID) -> Void,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.items = items
        self._selection = selection
        self.leaf = leaf
        self.removeLabel = removeLabel
        self.asksBeforeRemoving = asksBeforeRemoving
        self.onRemove = onRemove
        self.row = row
    }

    var body: some View {
        let ids = items.map(\.id)
        let stop = [selection, anchor].lazy.compactMap { $0 }.first { ids.contains($0) } ?? ids.first
        let binding = $selection
        ForEach(items) { item in
            let id = item.id
            let isSelected = selection == id
            row(item)
                .contentShape(Rectangle())
                .onTapGesture { selection = id }
                .environment(\.selectRuleRow, { binding.wrappedValue = id })
                // A grouped form ignores listRowBackground, so the wash reaches into the row's own margins.
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                            .fill(DS.Color.selectionWash)
                            .padding(.horizontal, -6)
                            .padding(.vertical, -5)
                    }
                }
                .focusable(id == stop)
                .focused($focused, equals: id)
                .onMoveCommand { move($0, from: id, in: ids) }
                .onDeleteCommand { removeFromKeyboard(id, in: ids) }
                .contextMenu {
                    Button(removeLabel) { onRemove(id) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityAction { selection = id }
                .accessibilityAction(named: Text(removeLabel)) { onRemove(id) }
                .axLeaf(leaf)
        }
    }

    /// With nothing chosen, the first arrow chooses the row that has the keyboard.
    private func move(_ direction: MoveCommandDirection, from id: Item.ID, in ids: [Item.ID]) {
        guard let index = ids.firstIndex(of: id) else { return }
        let target: Int
        switch direction {
        case .up: target = selection == id ? index - 1 : index
        case .down: target = selection == id ? index + 1 : index
        default: return
        }
        guard ids.indices.contains(target) else { return }
        selection = ids[target]
        focused = ids[target]
    }

    /// The keyboard stays on the next row, unchosen, so a second ⌫ can't take another rule.
    private func removeFromKeyboard(_ id: Item.ID, in ids: [Item.ID]) {
        guard selection == id else { return }
        onRemove(id)
        guard !asksBeforeRemoving, let index = ids.firstIndex(of: id) else { return }
        let rest = ids.filter { $0 != id }
        let next = rest.isEmpty ? nil : rest[min(index, rest.count - 1)]
        selection = nil
        anchor = next
        focused = next
    }
}

private struct SelectsRuleRowOnFocus: ViewModifier {
    @Environment(\.selectRuleRow) private var select
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, isFocused in
                if isFocused { select?() }
            }
    }
}

/// The foot of an editable list, inside its box: + and − at the leading edge, a ⋯ menu at the trailing one.
struct RuleListBar<AddItems: View, MoreItems: View>: View {
    private let leafPrefix: String
    private let addLabel: LocalizedStringKey
    private let removeLabel: LocalizedStringKey
    private let canRemove: Bool
    private let onAdd: (() -> Void)?
    private let addItems: AddItems
    private let onRemove: () -> Void
    private let moreItems: MoreItems
    private let hasMore: Bool

    private init(
        leafPrefix: String, addLabel: LocalizedStringKey, removeLabel: LocalizedStringKey, canRemove: Bool,
        onAdd: (() -> Void)?, addItems: AddItems, onRemove: @escaping () -> Void, moreItems: MoreItems, hasMore: Bool
    ) {
        self.leafPrefix = leafPrefix
        self.addLabel = addLabel
        self.removeLabel = removeLabel
        self.canRemove = canRemove
        self.onAdd = onAdd
        self.addItems = addItems
        self.onRemove = onRemove
        self.moreItems = moreItems
        self.hasMore = hasMore
    }

    var body: some View {
        HStack(spacing: 2) {
            addControl
            Divider()
                .frame(height: 14)
            Button(action: onRemove) {
                glyph("minus")
            }
            .disabled(!canRemove)
            .help(removeLabel)
            .accessibilityLabel(Text(removeLabel))
            .axLeaf("\(leafPrefix).Button.Remove")
            Spacer(minLength: 0)
            if hasMore {
                Menu {
                    moreItems
                } label: {
                    glyph("ellipsis.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityRepresentation { Menu("More") { moreItems } }
                .axLeaf("\(leafPrefix).Menu.More")
            }
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var addControl: some View {
        if let onAdd {
            Button(action: onAdd) {
                glyph("plus")
            }
            .help(addLabel)
            .accessibilityLabel(Text(addLabel))
            .axLeaf("\(leafPrefix).Button.Add")
        } else {
            Menu {
                addItems
            } label: {
                glyph("plus")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(addLabel)
            .accessibilityRepresentation { Menu(addLabel) { addItems } }
            .axLeaf("\(leafPrefix).Menu.Add")
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
    }
}

extension RuleListBar where AddItems == EmptyView, MoreItems == EmptyView {
    init(
        leafPrefix: String, addLabel: LocalizedStringKey, removeLabel: LocalizedStringKey, canRemove: Bool,
        onAdd: @escaping () -> Void, onRemove: @escaping () -> Void
    ) {
        self.init(
            leafPrefix: leafPrefix, addLabel: addLabel, removeLabel: removeLabel, canRemove: canRemove,
            onAdd: onAdd, addItems: EmptyView(), onRemove: onRemove, moreItems: EmptyView(), hasMore: false
        )
    }
}

extension RuleListBar where AddItems == EmptyView {
    init(
        leafPrefix: String, addLabel: LocalizedStringKey, removeLabel: LocalizedStringKey, canRemove: Bool,
        onAdd: @escaping () -> Void, onRemove: @escaping () -> Void, @ViewBuilder more: () -> MoreItems
    ) {
        self.init(
            leafPrefix: leafPrefix, addLabel: addLabel, removeLabel: removeLabel, canRemove: canRemove,
            onAdd: onAdd, addItems: EmptyView(), onRemove: onRemove, moreItems: more(), hasMore: true
        )
    }
}

extension RuleListBar where MoreItems == EmptyView {
    init(
        leafPrefix: String, addLabel: LocalizedStringKey, removeLabel: LocalizedStringKey, canRemove: Bool,
        @ViewBuilder addMenu: () -> AddItems, onRemove: @escaping () -> Void
    ) {
        self.init(
            leafPrefix: leafPrefix, addLabel: addLabel, removeLabel: removeLabel, canRemove: canRemove,
            onAdd: nil, addItems: addMenu(), onRemove: onRemove, moreItems: EmptyView(), hasMore: false
        )
    }
}
