import SwiftUI

struct SearchPill: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var prompt: String?
    var clearsOnEscape: Bool
    var identifier: String
    var clearButtonIdentifier: String
    /// A field the user reached by opening something takes the keyboard; one that is just there does not.
    var focusesOnAppear: Bool

    @FocusState private var focused: Bool

    init(
        text: Binding<String>,
        placeholder: LocalizedStringKey = "Search",
        prompt: String? = nil,
        clearsOnEscape: Bool = false,
        identifier: String = "search.field",
        clearButtonIdentifier: String = "search.field.clear",
        focusesOnAppear: Bool = false
    ) {
        self._text = text
        self.placeholder = placeholder
        self.prompt = prompt
        self.clearsOnEscape = clearsOnEscape
        self.identifier = identifier
        self.clearButtonIdentifier = clearButtonIdentifier
        self.focusesOnAppear = focusesOnAppear
    }

    /// Esc has to keep reaching the sheet or window unless a screen asked for it and has text.
    enum EscapeOutcome: Equatable {
        case clear
        case ignore
    }

    static func escapeOutcome(clearsOnEscape: Bool, isEmpty: Bool) -> EscapeOutcome {
        clearsOnEscape && !isEmpty ? .clear : .ignore
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            TextField(placeholder, text: $text, prompt: prompt.map(Text.init))
                .textFieldStyle(.plain)
                .font(DS.Font.secondary)
                .focused($focused)
                .accessibilityIdentifier(identifier)
                .onKeyPress(.escape) {
                    guard Self.escapeOutcome(clearsOnEscape: clearsOnEscape, isEmpty: text.isEmpty) == .clear
                    else { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier(clearButtonIdentifier)
            }
        }
        .padding(.horizontal, DS.Spacing.small)
        .padding(.vertical, DS.Spacing.snug)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Palette.subtleFill)
        )
        // A popover's field is not first responder on the frame it appears in, so the ask waits a runloop turn.
        .onAppear {
            guard focusesOnAppear else { return }
            DispatchQueue.main.async { focused = true }
        }
    }
}
