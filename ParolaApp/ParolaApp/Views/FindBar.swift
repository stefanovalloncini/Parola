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
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Color.separator.opacity(0.6), lineWidth: 1)
        )
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.top, DS.Spacing.small)
        .padding(.bottom, DS.Spacing.tight)
        .onAppear { queryFocused = true }
    }

    private var searchRow: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            BarPill {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                TextField("Find", text: $model.findQuery)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit { model.goToNextMatch() }
                    .accessibilityIdentifier("find.query")
                if !model.findQuery.isEmpty {
                    Text(matchSummary)
                        .font(DS.Font.captionMono)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 2)
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
                FindIconButton(
                    systemName: "chevron.down",
                    help: "Next match",
                    disabled: model.matches.isEmpty
                ) { model.goToNextMatch() }
                    .keyboardShortcut("g", modifiers: [.command])
                    .accessibilityIdentifier("find.next")
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

            Button {
                model.toggleFind()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close find")
            .accessibilityLabel("Close find")
            .accessibilityIdentifier("find.close")
        }
    }

    private var replaceRow: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            BarPill {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                TextField("Replace", text: $model.findReplacement)
                    .textFieldStyle(.plain)
                    .focused($replaceFocused)
                    .accessibilityIdentifier("find.replacement")
            }

            Button("Replace") { model.replaceCurrentMatch() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("=", modifiers: [.command])
                .disabled(model.matches.isEmpty)
                .accessibilityIdentifier("find.replace")

            Button("Replace All") { model.replaceAllMatches() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(DS.Color.accent)
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.matches.isEmpty)
                .accessibilityIdentifier("find.replaceAll")
        }
        .padding(.leading, 2)
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovered && !disabled ? DS.Color.surfaceElevated : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct FindToggleButton: View {
    let systemName: String
    let isOn: Bool
    let help: LocalizedStringKey
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(background)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }

    private var background: Color {
        if isOn { return DS.Color.accent }
        if hovered { return DS.Color.surfaceElevated }
        return .clear
    }
}
