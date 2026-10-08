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
    /// A row of an editable list: a click in it selects it, and the selection shows to the eye and to VoiceOver.
    func ruleListRow<ID: Hashable & Sendable>(_ id: ID, selection: Binding<ID?>, leaf: String) -> some View {
        modifier(RuleListRow(id: id, selection: selection, leaf: leaf))
    }

    /// A field in a rule-list row selects its row when it takes the keyboard.
    func selectsRuleRowOnFocus() -> some View {
        modifier(SelectsRuleRowOnFocus())
    }
}

private struct RuleListRow<ID: Hashable & Sendable>: ViewModifier {
    let id: ID
    @Binding var selection: ID?
    let leaf: String

    func body(content: Content) -> some View {
        let isSelected = selection == id
        let binding = $selection
        let id = id
        content
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
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction { selection = id }
            .axLeaf(leaf)
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
