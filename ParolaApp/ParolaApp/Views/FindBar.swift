import SwiftUI
import ParolaCore

struct FindBar: View {
    @EnvironmentObject var model: AppModel
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
        HStack(spacing: 12) {
            FindPill {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                TextField("Find", text: $model.findQuery)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit { model.goToNextMatch() }
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
                FindIconButton(
                    systemName: "chevron.down",
                    help: "Next match",
                    disabled: model.matches.isEmpty
                ) { model.goToNextMatch() }
                    .keyboardShortcut("g", modifiers: [.command])
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
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 12) {
            FindPill {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                TextField("Replace", text: $model.findReplacement)
                    .textFieldStyle(.plain)
                    .focused($replaceFocused)
            }

            Button("Replace") { model.replaceCurrentMatch() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.matches.isEmpty)

            Button("Replace All") { model.replaceAllMatches() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(DS.Color.accent)
                .disabled(model.matches.isEmpty)
        }
        .padding(.leading, 2)
    }

    private var matchSummary: String {
        if model.matches.isEmpty { return "No matches" }
        return "\(model.currentMatchIndex + 1) of \(model.matches.count)"
    }
}

private struct FindPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Color.surfaceElevated.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DS.Color.separator.opacity(0.4), lineWidth: 0.5)
            )
    }
}

private struct FindIconButton: View {
    let systemName: String
    let help: String
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
    let help: String
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
