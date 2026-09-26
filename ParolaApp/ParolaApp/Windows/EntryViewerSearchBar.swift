import SwiftUI
import ParolaCore

struct EntryViewerSearchBar: View {
    @Bindable var session: EntryWindowSession

    @FocusState private var queryFocused: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            BarPill {
                Image(systemName: "magnifyingglass")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryText)
                TextField("Find", text: $session.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit { session.goToNextMatch() }
                    .axLeaf("TextField.Search")
                if !session.searchQuery.isEmpty {
                    Text(verbatim: matchSummary)
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Color.secondaryText)
                        .padding(.trailing, DS.Spacing.hair)
                }
            }

            HStack(spacing: 0) {
                Button { session.goToPreviousMatch() } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(GlyphButtonStyle(tinted: true))
                .disabled(session.matches.isEmpty)
                .help("Previous match")
                .accessibilityLabel("Previous match")
                .axLeaf("Button.PreviousMatch")

                Button { session.goToNextMatch() } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(GlyphButtonStyle(tinted: true))
                .disabled(session.matches.isEmpty)
                .help("Next match")
                .accessibilityLabel("Next match")
                .axLeaf("Button.NextMatch")
            }

            Button { session.toggleSearch() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.secondaryText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close find")
            .accessibilityLabel("Close find")
            .axLeaf("Button.CloseSearch")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .task(id: session.searchFocusRequests) { await $queryFocused.request() }
    }

    private var matchSummary: String {
        if session.matches.isEmpty { return String(localized: "No matches") }
        return String(localized: "\(session.currentMatchIndex + 1) of \(session.matches.count)")
    }
}
