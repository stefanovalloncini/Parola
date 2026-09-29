import AppKit
import SwiftUI
import ParolaCore

struct FindBar: View {
    @Environment(AppModel.self) private var model
    @State private var showReplace = false
    @FocusState private var queryFocused: Bool
    @FocusState private var replaceFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            searchRow
            if showReplace { replaceRow }
        }
        .padding(DS.Spacing.small)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .stroke(DS.Color.separator.opacity(0.6), lineWidth: 1)
        )
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.top, DS.Spacing.small)
        .padding(.bottom, DS.Spacing.tight)
        .task(id: model.findFocusRequests) { await $queryFocused.request() }
        .onChange(of: model.findReplacements) { _, _ in refocusAfterReplacing() }
    }

    /// The field keeps the caret, in a fresh editing session: the old one's typing would take the first ⌘Z from the replacement.
    private func refocusAfterReplacing() {
        let inReplacement = replaceFocused
        if let window = NSApp.keyWindow, (window.firstResponder as? NSTextView)?.isFieldEditor == true,
           !window.makeFirstResponder(window.contentView) {
            window.makeFirstResponder(nil)
        }
        queryFocused = false
        replaceFocused = false
        Task {
            if inReplacement {
                await $replaceFocused.request(caretAtEnd: true)
            } else {
                await $queryFocused.request()
            }
        }
    }

    private var searchRow: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            BarPill {
                Image(systemName: "magnifyingglass")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryText)
                TextField("Find", text: $model.findQuery)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit { model.goToNextMatch() }
                    .accessibilityIdentifier("find.query")
                    .axLeaf("FindBar.TextField.Query")
                if !model.findQuery.isEmpty {
                    Text(matchSummary)
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Color.secondaryText)
                        .padding(.trailing, DS.Spacing.hair)
                }
            }

            HStack(spacing: 4) {
                FindIconButton(
                    systemName: "chevron.up",
                    help: "Previous match",
                    disabled: model.matches.isEmpty
                ) { model.goToPreviousMatch() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .accessibilityIdentifier("find.prev")
                    .accessibilityLabel("Previous match")
                FindIconButton(
                    systemName: "chevron.down",
                    help: "Next match",
                    disabled: model.matches.isEmpty
                ) { model.goToNextMatch() }
                    .keyboardShortcut("g", modifiers: [.command])
                    .accessibilityIdentifier("find.next")
                    .accessibilityLabel("Next match")
            }

            FindToggleButton(
                systemName: "textformat.size",
                isOn: model.findCaseSensitive,
                help: "Case-sensitive"
            ) { model.findCaseSensitive.toggle() }
                .accessibilityLabel("Case sensitive")

            FindToggleButton(
                systemName: "arrow.2.squarepath",
                isOn: showReplace,
                help: showReplace ? "Hide replace" : "Show replace"
            ) {
                showReplace.toggle()
                if showReplace { replaceFocused = true } else { queryFocused = true }
            }
            .accessibilityLabel(showReplace ? "Hide replace" : "Show replace")

            Button {
                model.toggleFind()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.secondaryText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close find")
            .accessibilityLabel("Close find")
            .accessibilityIdentifier("find.close")
            .axLeaf("FindBar.Button.Close")
        }
    }

    private var replaceRow: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            BarPill {
                Image(systemName: "arrow.2.squarepath")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryText)
                TextField("Replace", text: $model.findReplacement)
                    .textFieldStyle(.plain)
                    .focused($replaceFocused)
                    .accessibilityIdentifier("find.replacement")
                    .axLeaf("FindBar.TextField.Replace")
            }

            Button("Replace") { model.replaceCurrentMatch() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .keyboardShortcut("=", modifiers: [.command])
                .disabled(model.matches.isEmpty)
                .accessibilityIdentifier("find.replace")
                .axLeaf("FindBar.Button.Replace")

            Button("Replace All") { model.replaceAllMatches() }
                .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.matches.isEmpty)
                .accessibilityIdentifier("find.replaceAll")
                .axLeaf("FindBar.Button.ReplaceAll")
        }
        .padding(.leading, DS.Spacing.hair)
    }

    private var matchSummary: String {
        if model.matches.isEmpty { return String(localized: "No matches") }
        return String(localized: "\(model.currentMatchIndex + 1) of \(model.matches.count)")
    }
}

private struct FindIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary.opacity(0.85))
                .frame(width: 22, height: 22)
                .rowChrome(selected: false, hovered: hovered && !disabled, selection: .native)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .help(help)
    }
}

struct FindToggleButton: View {
    let systemName: String
    let isOn: Bool
    let help: LocalizedStringKey
    let action: () -> Void

    @State private var hovered = false

    /// Computed, not stored: a stored colour would freeze the palette the app launched with.
    static var selectionStyle: RowSelectionStyle { .prominent(fill: DS.Color.accentFill) }

    /// Set here, not through the chrome's foreground: an inner `foregroundStyle` wins over it.
    static func ink(isOn: Bool) -> Color {
        isOn ? DS.Color.onAccent : Color.primary.opacity(0.85)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(Self.ink(isOn: isOn))
                .frame(width: 22, height: 22)
                .rowChrome(selected: isOn, hovered: hovered, selection: Self.selectionStyle)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
