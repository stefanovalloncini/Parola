import SwiftUI
import ParolaCore

struct FindBar: View {
    @EnvironmentObject var model: AppModel
    @State private var showReplace = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in transcript", text: $model.findQuery)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit { model.goToNextMatch() }

                Toggle("Aa", isOn: $model.findCaseSensitive)
                    .toggleStyle(.button)
                    .help("Case-sensitive")
                    .accessibilityLabel("Case sensitive")

                if !model.findQuery.isEmpty {
                    Text(matchSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Button { model.goToPreviousMatch() } label: { Image(systemName: "chevron.up") }
                    .disabled(model.matches.isEmpty)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button { model.goToNextMatch() } label: { Image(systemName: "chevron.down") }
                    .disabled(model.matches.isEmpty)
                    .keyboardShortcut("g", modifiers: [.command])

                Button { showReplace.toggle() } label: {
                    Image(systemName: showReplace ? "arrow.up.right.square" : "arrow.down.right.square")
                }
                .help("Toggle replace")

                Button { model.toggleFind() } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if showReplace {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary)
                    TextField("Replace with", text: $model.findReplacement)
                        .textFieldStyle(.plain)
                    Button("Replace") { model.replaceCurrentMatch() }
                        .disabled(model.matches.isEmpty)
                    Button("Replace All") { model.replaceAllMatches() }
                        .disabled(model.matches.isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .background(.thinMaterial)
        .overlay(Divider(), alignment: .bottom)
        .onAppear { queryFocused = true }
    }

    private var matchSummary: String {
        if model.matches.isEmpty { return "no matches" }
        return "\(model.currentMatchIndex + 1) of \(model.matches.count)"
    }
}
